module testbench;
  bit Clk;
  int pass_count, fail_count;
  bit test_done;
  
  initial begin
    forever #5 Clk = ~Clk;
  end
  
  int count = 100;  // Increased test count for better coverage
  counter_if counterif(Clk);
  
  test test01(count, counterif, pass_count, fail_count, test_done);
  
  initial begin
    $dumpfile("dump.vcd");
    $dumpvars;
  end
  
  sync_counter_12bit DUT (
    .A(counterif.A),
    .Load(counterif.Load),
    .UpDown(counterif.UpDown),
    .Reset(counterif.Reset),
	.Enable(counterif.Enable),
    .Clk(Clk),
	.Count(counterif.Count)
  );
  
  initial begin
    wait(test_done);
    $display("-------- Test Summary --------");
    $display("Total Tests: %0d", count);
    $display("Passed: %0d", pass_count);
    $display("Failed: %0d", fail_count);
    $display("Coverage: %0.2f%%", (pass_count + fail_count) * 100.0 / count);
    $finish;
  end
  
endmodule

class transaction;
  rand bit [11:0] A;
  rand bit Load;
  rand bit UpDown;
  rand bit Reset;
  rand bit Enable;
  bit [11:0] Count;
  
endclass:transaction

class driver;
  mailbox gen2driv, driv2sb;
  virtual counter_if.DRIVER counterif;
  transaction d_trans;
  event driven;
  
  function new(mailbox gen2driv, driv2sb , virtual counter_if.DRIVER counterif, event driven);
    this.gen2driv=gen2driv;  
    this.counterif=counterif;
    this.driven=driven;
    this.driv2sb=driv2sb;
  endfunction
    
    
  task main(input int count);
    repeat(count) begin
      d_trans=new();
      gen2driv.get(d_trans);
    
      @(counterif.driver_cb);
      counterif.driver_cb.A <= d_trans.A;
      counterif.driver_cb.Load <= d_trans.Load;
	  counterif.driver_cb.Enable <= d_trans.Enable;
	  counterif.driver_cb.Reset <= d_trans.Reset;
	  counterif.driver_cb.UpDown <= d_trans.UpDown;
      driv2sb.put(d_trans);
      -> driven;
    end
      
  endtask:main
  
endclass:driver

interface counter_if(input clk);
  logic [11:0] A, Count;
  logic Load, UpDown, Reset, Enable;
  
  clocking driver_cb @(negedge clk);
    default input #1 output #1;
    output A, Load, UpDown, Reset, Enable;
  endclocking
  
  clocking mon_cb @(negedge clk);
    default input #1 output #1;
    input A, Load, UpDown, Reset, Enable, Count; 
  endclocking
  
  modport DRIVER (clocking driver_cb, input clk);
  modport MONITOR (clocking mon_cb, input clk);
    
endinterface

class generator;
  mailbox gen2driv;
  transaction g_trans, custom_trans;
  
  function new(mailbox gen2driv);
    this.gen2driv=gen2driv;
  endfunction
  
  task main(input int count);
    repeat(count) begin
      g_trans=new();
      g_trans=new custom_trans;
      assert(g_trans.randomize());
      gen2driv.put(g_trans);
    end
  endtask:main
  
endclass:generator

class monitor;
  mailbox mon2sb;
  virtual counter_if.MONITOR counterif;
  transaction m_trans;
  event driven;
  
  function new(mailbox mon2sb, virtual counter_if.MONITOR counterif, event driven);
    this.mon2sb=mon2sb;
    this.counterif=counterif;
    this.driven=driven;
  endfunction
  
  task main(input int count);
    @(driven);
    @(counterif.mon_cb);
    repeat(count) begin
      m_trans=new();	// It seems we only care about DUT output Count from Monitor
      @(posedge counterif.clk);
      m_trans.Count = counterif.mon_cb.Count;
      mon2sb.put(m_trans);
    end
  endtask:main
  
  
endclass:monitor

class scoreboard;
  mailbox driv2sb;
  mailbox mon2sb;
  
  transaction d_trans;
  transaction m_trans;
  
  event driven;
  
  int pass_count, fail_count;
  bit test_result;  // 1 for pass, 0 for fail

  function new(mailbox driv2sb, mon2sb);
    this.driv2sb = driv2sb;
    this.mon2sb = mon2sb;
    this.pass_count = 0;
    this.fail_count = 0;
  endfunction
  
  task main(input int count);
    $display("------------------Scoreboard Test Starts--------------------");
    repeat(count) begin
      m_trans = new();
      mon2sb.get(m_trans);
      report();
      
      if(test_result) begin
        pass_count++;
        $display("Passed : A=%d Reset=%d Load=%d Enable=%d UpDown=%d Expected Count=%d  Resulted Count=%d", d_trans.A, d_trans.Reset, d_trans.Load, d_trans.Enable, d_trans.UpDown, d_trans.Count, m_trans.Count);
      end else begin
        fail_count++;
        $display("Failed : A=%d Reset=%d Load=%d Enable=%d UpDown=%d Expected Count=%d  Resulted Count=%d", d_trans.A, d_trans.Reset, d_trans.Load, d_trans.Enable, d_trans.UpDown, d_trans.Count, m_trans.Count);
      end
    end
    $display("------------------Scoreboard Test Ends--------------------");
    $display("Total Passes: %0d, Total Fails: %0d", pass_count, fail_count);
  endtask

  task report();
    d_trans = new();
    driv2sb.get(d_trans);
    
	if (d_trans.Reset) begin
		// Reset has the highest priority
		d_trans.Count <= 12'b0;
	end
	else if (d_trans.Load) begin
		// Load A into Count when Load is high
		d_trans.Count <= d_trans.A;
	end
	else if (d_trans.Enable) begin
		// Only count if Enable is high
		if (d_trans.UpDown) begin
			// Up counting with wraparound
		  if (d_trans.Count == 2**12 - 1) begin
			  d_trans.Count <= 12'b0;  // Wrap around to max value when 0 is reached
			  // $display("Time=%t | Up Count wraparound. Count set to min value (0).", $time);
		  end
		  else begin
			  d_trans.Count++;
			  // $display("Time=%t | Up Count. Count incremented to %d.", $time, Count);
		  end
		end
		else if (~d_trans.UpDown) begin
			// Down counting with wraparound
			//$display("Time=%t | Down Count logic entered. Current Count=%d.", $time, Count);
			if (d_trans.Count == 12'b0) begin
				d_trans.Count <= 2**12 - 1;  // Wrap around to max value when 0 is reached
				//$display("Time=%t | Down Count wraparound. Count set to max value (4095).", $time);
			end
			else begin
				d_trans.Count--;
				//$display("Time=%t | Down Count. Count decremented to %d.", $time, Count);
			end
		end
	end
    
    
    test_result = (m_trans.Count == d_trans.Count);
  endtask
                     
endclass

class environment;
  mailbox gen2driv;
  mailbox driv2sb;
  mailbox mon2sb;
  
  generator gen;
  driver drv;
  monitor mon;
  scoreboard scb;
  
  event driven;
  
  virtual counter_if counterif;
  
  function new(virtual counter_if counterif);
    this.counterif = counterif;
    gen2driv = new();
    driv2sb = new();
    mon2sb = new();
    
    gen = new(gen2driv);
    drv = new(gen2driv, driv2sb, counterif.DRIVER, driven);
    mon = new(mon2sb, counterif.MONITOR, driven);
    scb = new(driv2sb, mon2sb);
  endfunction
  
  task main(input int count);
    fork
      gen.main(count);
      drv.main(count);
      mon.main(count);
      scb.main(count);
    join
  endtask

  function int get_pass_count();
    return scb.pass_count;
  endfunction

  function int get_fail_count();
    return scb.fail_count;
  endfunction
endclass

program test(input int count, counter_if counterif, output int pass_count, output int fail_count, output bit test_done);
  environment env;
  
  class testcase01 extends transaction;
  constraint c_A {
    A == 12'b0 || A == 12'hFFF || A inside {[25:30]}; // Include all intermediate values
  }
  endclass:testcase01
  
  initial begin
    testcase01 testcase01handle;
    testcase01handle = new();
    
    env = new(counterif);
    env.gen.custom_trans = testcase01handle;
    env.main(count);
    
    pass_count = env.get_pass_count();
    fail_count = env.get_fail_count();
    test_done = 1'b1;
  end
  
endprogram:test