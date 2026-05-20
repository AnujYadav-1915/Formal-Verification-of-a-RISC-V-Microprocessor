# =============================================================================
# Project: Formal Verification of a RISC-V Microprocessor
# Script: run_jasper.tcl
# Description: Automated JasperGold script to load, elaborate, and verify core.
# =============================================================================

# Clear design database
clear -all

# Set target compile mode
set_analyze_option -sv312 on

# Analyze design files and assertions
analyze -sv {
    ../rtl/rv32i_core.sv
    ../tb/rv32i_sva.sv
    ../tb/rv32i_bind.sv
}

# Elaborate top module
elaborate -top rv32i_core

# Define clock and reset behavior
clock clk
reset -expression {!rst_n}

# Configure proof grid settings
set_engine_mode {B K I A}
set_max_depth 25

# Run the properties check
prove -all

# Generate reports
report -summary -file formal_results.rpt
report -assertions -file assertions_details.rpt

# Exit tool execution
exit
