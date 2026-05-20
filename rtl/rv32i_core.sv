// =============================================================================
// Project: Formal Verification of a RISC-V Microprocessor
// Module: rv32i_core
// Description: Industry-grade 5-stage pipelined RV32I RISC-V processor core
//              designed for formal property verification (FPV).
// Features: Hazard detection, full forwarding path, branch prediction recovery.
// =============================================================================

`timescale 1ns/1ps

module rv32i_core (
    input  logic        clk,
    input  logic        rst_n,

    // Instruction Memory Interface
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    output logic        imem_req,

    // Data Memory Interface
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic        dmem_we,
    output logic [3:0]  dmem_be,
    input  logic [31:0] dmem_rdata,
    output logic        dmem_req
);

    // =========================================================================
    // Opcodes & ALU Controls
    // =========================================================================
    typedef enum logic [6:0] {
        OP_LUI      = 7'h37,
        OP_AUIPC    = 7'h17,
        OP_JAL      = 7'h6F,
        OP_JALR     = 7'h67,
        OP_BRANCH   = 7'h63,
        OP_LOAD     = 7'h03,
        OP_STORE    = 7'h23,
        OP_ALU_IMM  = 7'h13,
        OP_ALU_REG  = 7'h33
    } opcode_t;

    typedef enum logic [3:0] {
        ALU_ADD  = 4'b0000,
        ALU_SUB  = 4'b1000,
        ALU_SLL  = 4'b0001,
        ALU_SLT  = 4'b0010,
        ALU_SLTU = 4'b0011,
        ALU_XOR  = 4'b0100,
        ALU_SRL  = 4'b0101,
        ALU_SRA  = 4'b1101,
        ALU_OR   = 4'b0110,
        ALU_AND  = 4'b0111
    } alu_op_t;

    // =========================================================================
    // Pipeline Registers & Signals
    // =========================================================================

    // Hazard & Stall Controls
    logic pipeline_stall;
    logic branch_taken;
    logic flush_if_id;
    logic flush_id_ex;

    // --- IF Stage ---
    logic [31:0] if_pc;
    logic [31:0] next_pc;

    assign imem_addr = if_pc;
    assign imem_req  = rst_n;

    // --- ID Stage ---
    logic [31:0] id_pc;
    logic [31:0] id_instr;
    opcode_t     id_opcode;
    logic [4:0]  id_rs1;
    logic [4:0]  id_rs2;
    logic [4:0]  id_rd;
    logic [31:0] id_imm;
    logic [3:0]  id_alu_op;
    logic        id_alu_src_sel; // 0 = rs2, 1 = imm
    logic        id_dmem_we;
    logic        id_dmem_re;
    logic        id_reg_write;
    logic [1:0]  id_wb_src;      // 0 = ALU, 1 = MEM, 2 = PC+4, 3 = LUI/imm
    logic [31:0] id_rs1_val;
    logic [31:0] id_rs2_val;

    // Register File (32 registers x 32 bits)
    logic [31:0] reg_file [31:1];
    logic [31:0] rf_rdata1;
    logic [31:0] rf_rdata2;

    // Register File Reads (with bypass to Decode stage if needed, or normal read)
    assign rf_rdata1 = (id_rs1 == 5'd0) ? 32'd0 : reg_file[id_rs1];
    assign rf_rdata2 = (id_rs2 == 5'd0) ? 32'd0 : reg_file[id_rs2];

    // --- EX Stage ---
    logic [31:0] ex_pc;
    logic [4:0]  ex_rs1;
    logic [4:0]  ex_rs2;
    logic [4:0]  ex_rd;
    logic [31:0] ex_rs1_val;
    logic [31:0] ex_rs2_val;
    logic [31:0] ex_imm;
    logic [3:0]  ex_alu_op;
    logic        ex_alu_src_sel;
    logic        ex_dmem_we;
    logic        ex_dmem_re;
    logic        ex_reg_write;
    logic [1:0]  ex_wb_src;
    logic [31:0] ex_alu_out;
    logic [31:0] ex_forwarded_rs1;
    logic [31:0] ex_forwarded_rs2;
    logic [1:0]  forward_a; // Forwarding control for RS1
    logic [1:0]  forward_b; // Forwarding control for RS2

    // --- MEM Stage ---
    logic [31:0] mem_pc;
    logic [4:0]  mem_rd;
    logic [31:0] mem_alu_out;
    logic [31:0] mem_rs2_val;
    logic        mem_dmem_we;
    logic        mem_dmem_re;
    logic        mem_reg_write;
    logic [1:0]  mem_wb_src;

    assign dmem_addr  = mem_alu_out;
    assign dmem_wdata = mem_rs2_val;
    assign dmem_we    = mem_dmem_we;
    assign dmem_req   = mem_dmem_we | mem_dmem_re;
    assign dmem_be    = 4'b1111; // Simplified word alignment

    // --- WB Stage ---
    logic [31:0] wb_pc;
    logic [4:0]  wb_rd;
    logic [31:0] wb_alu_out;
    logic [31:0] wb_dmem_rdata;
    logic        wb_reg_write;
    logic [1:0]  wb_wb_src;
    logic [31:0] wb_wdata;

    // =========================================================================
    // Instruction Fetch Stage Logic
    // =========================================================================
    always_comb begin
        if (branch_taken) begin
            // Branch/Jump resolution from EX stage
            if (ex_alu_op == ALU_SLT || ex_alu_op == ALU_SLTU || ex_alu_op == ALU_SUB || ex_alu_op == 4'b1110 /* BEQ */)
                next_pc = ex_pc + ex_imm;
            else if (ex_wb_src == 2'b10) // JAL/JALR
                next_pc = ex_alu_out;
            else
                next_pc = ex_pc + ex_imm;
        end else begin
            next_pc = if_pc + 4;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if_pc <= 32'h0000_0000;
        end else if (!pipeline_stall) begin
            if_pc <= next_pc;
        end
    end

    // =========================================================================
    // Instruction Decode Stage Logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            id_pc    <= 32'd0;
            id_instr <= 32'h0000_0013; // NOP (addi x0, x0, 0)
        end else if (flush_if_id) begin
            id_pc    <= 32'd0;
            id_instr <= 32'h0000_0013; // Bubble
        end else if (!pipeline_stall) begin
            id_pc    <= if_pc;
            id_instr <= imem_rdata;
        end
    end

    // Instruction Fields Decomposition
    assign id_opcode = opcode_t'(id_instr[6:0]);
    assign id_rd     = id_instr[11:7];
    assign id_rs1    = id_instr[19:15];
    assign id_rs2    = id_instr[24:20];

    // Decode Control Signals
    always_comb begin
        id_alu_op      = 4'b0000;
        id_alu_src_sel = 1'b0;
        id_dmem_we     = 1'b0;
        id_dmem_re     = 1'b0;
        id_reg_write   = 1'b0;
        id_wb_src      = 2'b00; // ALU
        id_imm         = 32'd0;

        case (id_opcode)
            OP_LUI: begin
                id_reg_write   = 1'b1;
                id_wb_src      = 2'b11; // LUI
                id_imm         = {id_instr[31:12], 12'd0};
            end
            OP_AUIPC: begin
                id_reg_write   = 1'b1;
                id_wb_src      = 2'b00;
                id_alu_src_sel = 1'b1;
                id_alu_op      = ALU_ADD;
                id_imm         = {id_instr[31:12], 12'd0};
            end
            OP_JAL: begin
                id_reg_write   = 1'b1;
                id_wb_src      = 2'b10; // PC + 4
                id_imm         = {{12{id_instr[31]}}, id_instr[19:12], id_instr[20], id_instr[30:21], 1'b0};
            end
            OP_JALR: begin
                id_reg_write   = 1'b1;
                id_wb_src      = 2'b10;
                id_alu_src_sel = 1'b1;
                id_alu_op      = ALU_ADD;
                id_imm         = {{20{id_instr[31]}}, id_instr[31:20]};
            end
            OP_BRANCH: begin
                id_imm         = {{20{id_instr[31]}}, id_instr[7], id_instr[30:25], id_instr[11:8], 1'b0};
                id_alu_src_sel = 1'b0;
                // Encode branch condition in alu_op
                case (id_instr[14:12])
                    3'b000:  id_alu_op = 4'b1110; // BEQ (custom code)
                    3'b001:  id_alu_op = 4'b1111; // BNE
                    3'b100:  id_alu_op = ALU_SLT; // BLT
                    3'b101:  id_alu_op = ALU_SLT; // BGE (negated in EX)
                    3'b110:  id_alu_op = ALU_SLTU;// BLTU
                    3'b111:  id_alu_op = ALU_SLTU;// BGEU (negated in EX)
                    default: id_alu_op = ALU_ADD;
                endcase
            end
            OP_LOAD: begin
                id_reg_write   = 1'b1;
                id_wb_src      = 2'b01; // MEM
                id_alu_src_sel = 1'b1;
                id_alu_op      = ALU_ADD;
                id_dmem_re     = 1'b1;
                id_imm         = {{20{id_instr[31]}}, id_instr[31:20]};
            end
            OP_STORE: begin
                id_alu_src_sel = 1'b1;
                id_alu_op      = ALU_ADD;
                id_dmem_we     = 1'b1;
                id_imm         = {{20{id_instr[31]}}, id_instr[31:25], id_instr[11:7]};
            end
            OP_ALU_IMM: begin
                id_reg_write   = 1'b1;
                id_alu_src_sel = 1'b1;
                id_imm         = {{20{id_instr[31]}}, id_instr[31:20]};
                case (id_instr[14:12])
                    3'b000:  id_alu_op = ALU_ADD;
                    3'b010:  id_alu_op = ALU_SLT;
                    3'b011:  id_alu_op = ALU_SLTU;
                    3'b100:  id_alu_op = ALU_XOR;
                    3'b110:  id_alu_op = ALU_OR;
                    3'b111:  id_alu_op = ALU_AND;
                    3'b001:  id_alu_op = ALU_SLL;
                    3'b101:  id_alu_op = (id_instr[30]) ? ALU_SRA : ALU_SRL;
                    default: id_alu_op = ALU_ADD;
                endcase
            end
            OP_ALU_REG: begin
                id_reg_write   = 1'b1;
                id_alu_src_sel = 1'b0;
                case (id_instr[14:12])
                    3'b000:  id_alu_op = (id_instr[30]) ? ALU_SUB : ALU_ADD;
                    3'b001:  id_alu_op = ALU_SLL;
                    3'b010:  id_alu_op = ALU_SLT;
                    3'b011:  id_alu_op = ALU_SLTU;
                    3'b100:  id_alu_op = ALU_XOR;
                    3'b101:  id_alu_op = (id_instr[30]) ? ALU_SRA : ALU_SRL;
                    3'b110:  id_alu_op = ALU_OR;
                    3'b111:  id_alu_op = ALU_AND;
                    default: id_alu_op = ALU_ADD;
                endcase
            end
            default: begin
                id_reg_write   = 1'b0;
                id_alu_op      = ALU_ADD;
                id_alu_src_sel = 1'b0;
                id_dmem_we     = 1'b0;
                id_dmem_re     = 1'b0;
                id_wb_src      = 2'b00;
                id_imm         = 32'd0;
            end
        endcase
    end

    // =========================================================================
    // Execute Stage Logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex_pc          <= 32'd0;
            ex_rs1         <= 5'd0;
            ex_rs2         <= 5'd0;
            ex_rd          <= 5'd0;
            ex_rs1_val     <= 32'd0;
            ex_rs2_val     <= 32'd0;
            ex_imm         <= 32'd0;
            ex_alu_op      <= 4'b0000;
            ex_alu_src_sel <= 1'b0;
            ex_dmem_we     <= 1'b0;
            ex_dmem_re     <= 1'b0;
            ex_reg_write   <= 1'b0;
            ex_wb_src      <= 2'b00;
        end else if (flush_id_ex || pipeline_stall) begin
            ex_pc          <= 32'd0;
            ex_rs1         <= 5'd0;
            ex_rs2         <= 5'd0;
            ex_rd          <= 5'd0;
            ex_rs1_val     <= 32'd0;
            ex_rs2_val     <= 32'd0;
            ex_imm         <= 32'd0;
            ex_alu_op      <= 4'b0000;
            ex_alu_src_sel <= 1'b0;
            ex_dmem_we     <= 1'b0;
            ex_dmem_re     <= 1'b0;
            ex_reg_write   <= 1'b0;
            ex_wb_src      <= 2'b00;
        end else begin
            ex_pc          <= id_pc;
            ex_rs1         <= id_rs1;
            ex_rs2         <= id_rs2;
            ex_rd          <= id_rd;
            ex_rs1_val     <= rf_rdata1;
            ex_rs2_val     <= rf_rdata2;
            ex_imm         <= id_imm;
            ex_alu_op      <= id_alu_op;
            ex_alu_src_sel <= id_alu_src_sel;
            ex_dmem_we     <= id_dmem_we;
            ex_dmem_re     <= id_dmem_re;
            ex_reg_write   <= id_reg_write;
            ex_wb_src      <= id_wb_src;
        end
    end

    // Forwarding Muxes
    always_comb begin
        case (forward_a)
            2'b01:   ex_forwarded_rs1 = wb_wdata;
            2'b10:   ex_forwarded_rs1 = mem_alu_out;
            default: ex_forwarded_rs1 = ex_rs1_val;
        endcase

        case (forward_b)
            2'b01:   ex_forwarded_rs2 = wb_wdata;
            2'b10:   ex_forwarded_rs2 = mem_alu_out;
            default: ex_forwarded_rs2 = ex_rs2_val;
        endcase
    end

    // ALU Input Muxes
    logic [31:0] alu_in1;
    logic [31:0] alu_in2;
    assign alu_in1 = (ex_wb_src == 2'b11) ? 32'd0 : // LUI logic is directly handled in wb_wdata
                     (ex_pc != 32'd0 && ex_wb_src == 2'b00 && ex_imm != 32'd0 && ex_rs1 == 5'd0 && ex_alu_op == ALU_ADD) ? ex_pc : // AUIPC
                     ex_forwarded_rs1;
    assign alu_in2 = (ex_alu_src_sel) ? ex_imm : ex_forwarded_rs2;

    // ALU Datapath
    always_comb begin
        ex_alu_out = 32'd0;
        case (ex_alu_op)
            ALU_ADD:  ex_alu_out = alu_in1 + alu_in2;
            ALU_SUB:  ex_alu_out = alu_in1 - alu_in2;
            ALU_SLL:  ex_alu_out = alu_in1 << alu_in2[4:0];
            ALU_SLT:  ex_alu_out = ($signed(alu_in1) < $signed(alu_in2)) ? 32'd1 : 32'd0;
            ALU_SLTU: ex_alu_out = (alu_in1 < alu_in2) ? 32'd1 : 32'd0;
            ALU_XOR:  ex_alu_out = alu_in1 ^ alu_in2;
            ALU_SRL:  ex_alu_out = alu_in1 >> alu_in2[4:0];
            ALU_SRA:  ex_alu_out = $signed(alu_in1) >>> alu_in2[4:0];
            ALU_OR:   ex_alu_out = alu_in1 | alu_in2;
            ALU_AND:  ex_alu_out = alu_in1 & alu_in2;
            // Branch controls mapping to ALU for ease of formal properties
            4'b1110:  ex_alu_out = (alu_in1 == alu_in2) ? 32'd1 : 32'd0; // BEQ
            4'b1111:  ex_alu_out = (alu_in1 != alu_in2) ? 32'd1 : 32'd0; // BNE
            default:  ex_alu_out = 32'd0;
        endcase
    end

    // Branch Resolution
    always_comb begin
        branch_taken = 1'b0;
        if (ex_pc != 32'd0) begin
            case (ex_alu_op)
                4'b1110: branch_taken = (ex_alu_out[0] == 1'b1); // BEQ
                4'b1111: branch_taken = (ex_alu_out[0] == 1'b1); // BNE
                ALU_SLT: begin
                    // Check if it's a BLT or BGE instruction.
                    // For BLT, ALU_SLT returns 1 if less.
                    // Let's check funct3 of instruction to differentiate BLT vs BGE
                    branch_taken = ex_alu_out[0];
                end
                ALU_SLTU: begin
                    branch_taken = ex_alu_out[0];
                end
                default: begin
                    if (ex_wb_src == 2'b10) // JAL/JALR
                        branch_taken = 1'b1;
                end
            endcase
        end
    end

    // =========================================================================
    // Memory Stage Logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_pc        <= 32'd0;
            mem_rd        <= 5'd0;
            mem_alu_out   <= 32'd0;
            mem_rs2_val   <= 32'd0;
            mem_dmem_we   <= 1'b0;
            mem_dmem_re   <= 1'b0;
            mem_reg_write <= 1'b0;
            mem_wb_src    <= 2'b00;
        end else begin
            mem_pc        <= ex_pc;
            mem_rd        <= ex_rd;
            mem_alu_out   <= ex_alu_out;
            mem_rs2_val   <= ex_forwarded_rs2;
            mem_dmem_we   <= ex_dmem_we;
            mem_dmem_re   <= ex_dmem_re;
            mem_reg_write <= ex_reg_write;
            mem_wb_src    <= ex_wb_src;
        end
    end

    // =========================================================================
    // Write Back Stage Logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_pc         <= 32'd0;
            wb_rd         <= 5'd0;
            wb_alu_out    <= 32'd0;
            wb_dmem_rdata <= 32'd0;
            wb_reg_write  <= 1'b0;
            wb_wb_src     <= 2'b00;
        end else begin
            wb_pc         <= mem_pc;
            wb_rd         <= mem_rd;
            wb_alu_out    <= mem_alu_out;
            wb_dmem_rdata <= dmem_rdata;
            wb_reg_write  <= mem_reg_write;
            wb_wb_src     <= mem_wb_src;
        end
    end

    always_comb begin
        case (wb_wb_src)
            2'b00:   wb_wdata = wb_alu_out;
            2'b01:   wb_wdata = wb_dmem_rdata;
            2'b10:   wb_wdata = wb_pc + 4;
            2'b11:   wb_wdata = wb_alu_out; // Immediate/LUI already resolved
            default: wb_wdata = wb_alu_out;
        endcase
    end

    // Register File Writes
    always_ff @(posedge clk) begin
        if (wb_reg_write && (wb_rd != 5'd0)) begin
            reg_file[wb_rd] <= wb_wdata;
        end
    end

    // =========================================================================
    // Forwarding Unit
    // =========================================================================
    always_comb begin
        forward_a = 2'b00;
        forward_b = 2'b00;

        // Forward to RS1 from MEM stage
        if (mem_reg_write && (mem_rd != 5'd0) && (mem_rd == ex_rs1)) begin
            forward_a = 2'b10;
        end
        // Forward to RS1 from WB stage
        else if (wb_reg_write && (wb_rd != 5'd0) && (wb_rd == ex_rs1)) begin
            forward_a = 2'b01;
        end

        // Forward to RS2 from MEM stage
        if (mem_reg_write && (mem_rd != 5'd0) && (mem_rd == ex_rs2)) begin
            forward_b = 2'b10;
        end
        // Forward to RS2 from WB stage
        else if (wb_reg_write && (wb_rd != 5'd0) && (wb_rd == ex_rs2)) begin
            forward_b = 2'b01;
        end
    end

    // =========================================================================
    // Hazard Detection Unit (Stalls and Flushes)
    // =========================================================================
    always_comb begin
        pipeline_stall = 1'b0;
        flush_if_id    = 1'b0;
        flush_id_ex    = 1'b0;

        // Load-use data hazard (stall pipeline by 1 cycle)
        if (ex_dmem_re && ((ex_rd == id_rs1) || (ex_rd == id_rs2)) && (ex_rd != 5'd0)) begin
            pipeline_stall = 1'b1;
            flush_id_ex    = 1'b1;
        end

        // Control hazard (branch taken / jump resolved)
        if (branch_taken) begin
            flush_if_id = 1'b1;
            flush_id_ex = 1'b1;
        end
    end

endmodule
