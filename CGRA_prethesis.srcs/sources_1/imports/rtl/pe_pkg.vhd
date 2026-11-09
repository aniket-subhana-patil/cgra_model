-------------------------------------------------------------------------------
-- pe_pkg.vhd : constants and helper functions for the CGRA processing element
--
-- Configuration word layout (MSB -> LSB), CFG_W = 20 + DATA_W bits:
--
--   [oneshot:1][op:3][selA:3][selB:3][shA:5][shB:5][imm:DATA_W]
--
--   op    : OP_NOP, OP_PASS, OP_ADD, OP_SUB, OP_MUL
--   sel*  : operand source (SRC_N/E/S/W, SRC_LOC, SRC_SELF, SRC_ZERO, SRC_IMM)
--   sh*   : shift of the operand before the ALU: bit 4 = direction
--           (0 = left, 1 = arithmetic right), bits 3..0 = amount (0..15)
--   imm   : immediate operand
--   oneshot: 1 = PE fires once per run (until 'clear'), 0 = fires every cycle
--            its operands are valid (e.g. accumulation through SRC_SELF)
--
-- ALU:  ADD : out = (A << shA) + (B << shB)      (shift-accumulate, LCC)
--       SUB : out = (A << shA) - (B << shB)
--       MUL : out = (A << shA) * (B << shB)      (baseline only, low DATA_W bits)
--       PASS: out = (A << shA)                   (routing / copy)
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

package pe_pkg is

  constant SHIFT_W : natural := 5;
  constant CFG_OVERHEAD : natural := 1 + 3 + 3 + 3 + SHIFT_W + SHIFT_W;  -- 20

  function cfg_width(data_w : natural) return natural;

  -- opcodes
  constant OP_NOP  : std_logic_vector(2 downto 0) := "000";
  constant OP_PASS : std_logic_vector(2 downto 0) := "001";
  constant OP_ADD  : std_logic_vector(2 downto 0) := "010";
  constant OP_SUB  : std_logic_vector(2 downto 0) := "011";
  constant OP_MUL  : std_logic_vector(2 downto 0) := "100";

  -- operand sources
  constant SRC_N    : std_logic_vector(2 downto 0) := "000";
  constant SRC_E    : std_logic_vector(2 downto 0) := "001";
  constant SRC_S    : std_logic_vector(2 downto 0) := "010";
  constant SRC_W    : std_logic_vector(2 downto 0) := "011";
  constant SRC_LOC  : std_logic_vector(2 downto 0) := "100";  -- local port (DMA / reg file)
  constant SRC_SELF : std_logic_vector(2 downto 0) := "101";  -- own output register
  constant SRC_ZERO : std_logic_vector(2 downto 0) := "110";
  constant SRC_IMM  : std_logic_vector(2 downto 0) := "111";

  -- helper to build a configuration word (for testbenches / config generators)
  function make_cfg(
    data_w  : natural;
    oneshot : std_logic;
    op      : std_logic_vector(2 downto 0);
    sel_a   : std_logic_vector(2 downto 0);
    sel_b   : std_logic_vector(2 downto 0);
    sh_a    : std_logic_vector(SHIFT_W - 1 downto 0);
    sh_b    : std_logic_vector(SHIFT_W - 1 downto 0);
    imm     : std_logic_vector) return std_logic_vector;

end package pe_pkg;

package body pe_pkg is

  function cfg_width(data_w : natural) return natural is
  begin
    return CFG_OVERHEAD + data_w;
  end function;

  function make_cfg(
    data_w  : natural;
    oneshot : std_logic;
    op      : std_logic_vector(2 downto 0);
    sel_a   : std_logic_vector(2 downto 0);
    sel_b   : std_logic_vector(2 downto 0);
    sh_a    : std_logic_vector(SHIFT_W - 1 downto 0);
    sh_b    : std_logic_vector(SHIFT_W - 1 downto 0);
    imm     : std_logic_vector) return std_logic_vector is
    variable imm_n : std_logic_vector(data_w - 1 downto 0);
  begin
    imm_n := imm;
    return oneshot & op & sel_a & sel_b & sh_a & sh_b & imm_n;
  end function;

end package body pe_pkg;
