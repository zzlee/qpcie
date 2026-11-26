`timescale 1ns/1ps
module sc7f0_flip_scheduler_tb;
    reg clk=0; always #4 clk=!clk;
    reg rst_n=0,run_ok=1,mode=0,submit=0,blank=0,busy=0,debt=0,quiet=1,done=0,abort_evt=0;
    reg issue_idle=1;
    reg [31:0] cookie=0, bytes=33177600, shown=0;
    reg [63:0] addr=0; reg [15:0] cap=128;
    wire [31:0] admitted,pending,active,retired,run_cookie;
    wire [63:0] run_addr; wire [15:0] run_cap;
    wire go,fault,drained;
    sc7f0_flip_scheduler dut(.*);
    task step; begin @(posedge clk); #1; end endtask
    task push(input integer n); begin
        cookie=n; addr=n*4096; submit=1; step; submit=0;
    end endtask
    task launch(input integer n); begin
        blank=1; step; blank=0;
        if (!go || run_cookie!=n || run_addr!=n*4096) $fatal(1,"launch %0d",n);
        // Delayed ingress busy: a second blank must not double-start or retire.
        blank=1; step; blank=0; if(!go || drained || run_cookie!=n) $fatal;
        busy=1;quiet=0;step;
        busy=0;quiet=1;done=1;step;done=0;
    end endtask
    integer n;
    initial begin
        step; rst_n=1; step; if(!drained) $fatal;
        mode=1;push(1);push(2);
        repeat(37) begin step; if(go || active || pending!=1 || admitted!=1) $fatal; end
        launch(1); repeat(23) begin step; if(active || !pending) $fatal; end
        shown=1;step;if(active!=1 || pending!=0) $fatal;
        if ($test$plusargs("reset_active") || $test$plusargs("reset_drained")) begin
            if ($test$plusargs("reset_drained")) begin
                mode=0;step;step;if(!drained || active!=0) $fatal;
            end else begin
                push(2);launch(2);if(active!=1 || pending!=2 || fault) $fatal;
            end
            rst_n=0;step;if(drained || admitted==0) $fatal;
            rst_n=1;mode=0;shown=2;repeat(10) begin step;if(!fault || drained || active || pending) $fatal;end
            mode=1;push(3);blank=1;step;if(!fault || drained || active || go || pending || admitted==3) $fatal;
            $display("FLIP_HEALTHY_EPOCH_PASS retained=%d stale_ack=2 after_link_reset",admitted);
            $finish;
        end
        repeat(600) begin launch(1);if(active!=1 || pending || retired) $fatal;end
        for(n=2;n<100;n=n+1) begin
            repeat($urandom_range(0,4)) launch(n-1);
            blank=$random;push(n);blank=0;
            if(go) begin
                if(run_cookie!=n-1) $fatal;
                done=1;step;done=0;
            end
            push(n+1000); if(admitted!=n) $fatal;
            launch(n); repeat($urandom_range(1,7)) begin
                step;if(active!=n-1 || pending!=n) $fatal;
            end
            shown=n;step;if(active!=n || retired!=n-1 || pending!=0) $fatal;
        end
        push(101);blank=1;step;blank=0;if(!go) $fatal;
        mode=0;issue_idle=0;quiet=0;
        repeat(30) begin step;if(!go || drained || fault) $fatal;end
        issue_idle=1;step;if(go || drained) $fatal;
        debt=1;repeat(12) begin step;if(drained) $fatal;end
        debt=0;quiet=1;step;if(!drained || pending || active) $fatal;
        mode=1;push(101);if(pending) $fatal;
        push(102);run_ok=0;step;run_ok=1;blank=1;step;
        if(!fault || go || drained) $fatal;
        mode=0;repeat(12) begin step;if(!fault || drained) $fatal;end
        // PCIe-only reset: compositor may still return this exact old cookie.
        rst_n=0;step;if(admitted!=102 || drained) $fatal;
        rst_n=1;shown=102;repeat(10) begin step;if(!fault || drained || active) $fatal;end
        mode=1;push(102);push(103);blank=1;step;
        if(admitted!=102 || pending || active || go || drained || !fault) $fatal;
        $display("FLIP_EPOCH_PASS retained=102; stale ack/reused AND fresh cookie refused after PCIe reset");
        $display("PASS 600 idle frames; random admission/late replay; start guard, retirement, disable/debt/reset");$finish;
    end
endmodule
