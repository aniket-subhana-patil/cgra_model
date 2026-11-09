-------------------------------------------------------------------------------
-- pe.vhd : Processing element of the CGRA for Linear Computation Coding
--
-- Blocks:  configuration memory -> decode -> operand routing muxes ->
--          operand shifters -> ALU -> output register (+ valid/done flags)
--
-- Dataflow firing rule: the PE fires in the first cycle in which its
-- configured operands are valid (neighbour output valid, local port valid,
-- or constant). The result is written to the output register at the clock
-- edge, so a PE has a latency of 1 cycle; neighbours read the output
-- register directly (nearest-neighbour mesh, 4 ports + local port).
-- Routing over distance d is done by PASS operations in intermediate PEs.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pe_pkg.all;

entity pe is
  generic (
    DATA_W    : natural := 16;
    CFG_DEPTH : natural := 4      -- number of configuration contexts
  );
  port (
    clk, rst   : in  std_logic;
    -- configuration port (write one context word per cycle)
    cfg_we     : in  std_logic;
    cfg_addr   : in  natural range 0 to CFG_DEPTH - 1;
    cfg_data   : in  std_logic_vector(cfg_width(DATA_W) - 1 downto 0);
    cfg_ctx    : in  natural range 0 to CFG_DEPTH - 1;   -- active context
    -- control
    clear      : in  std_logic;   -- start of a new run: clears valid/done
    -- neighbour inputs (their output registers) with valid flags
    in_n, in_e, in_s, in_w : in std_logic_vector(DATA_W - 1 downto 0);
    v_n,  v_e,  v_s,  v_w  : in std_logic;
    -- local input (DMA read data / register file)
    in_loc     : in  std_logic_vector(DATA_W - 1 downto 0);
    v_loc      : in  std_logic;
    -- output register
    out_data   : out std_logic_vector(DATA_W - 1 downto 0);
    out_valid  : out std_logic;
    fired      : out std_logic    -- pulses in the cycle the PE fires (statistics)
  );
end entity pe;

architecture rtl of pe is
  constant CFG_W : natural := cfg_width(DATA_W);

  type cfg_mem_t is array (0 to CFG_DEPTH - 1) of std_logic_vector(CFG_W - 1 downto 0);
  signal cfg_mem : cfg_mem_t := (others => (others => '0'));  -- NOP = 0

  signal cfg : std_logic_vector(CFG_W - 1 downto 0);

  -- decoded fields
  signal oneshot : std_logic;
  signal op      : std_logic_vector(2 downto 0);
  signal sel_a, sel_b : std_logic_vector(2 downto 0);
  signal sh_a, sh_b   : std_logic_vector(SHIFT_W - 1 downto 0) := (others => '0');
  signal imm     : signed(DATA_W - 1 downto 0);

  signal out_reg : signed(DATA_W - 1 downto 0) := (others => '0');
  signal valid_r : std_logic := '0';
  signal done_r  : std_logic := '0';

  signal opnd_a, opnd_b : signed(DATA_W - 1 downto 0);
  signal ok_a, ok_b     : std_logic;
  signal sa, sb         : signed(DATA_W - 1 downto 0);  -- shifted operands
  signal result         : signed(DATA_W - 1 downto 0);
  signal fire           : std_logic;

  -- routing multiplexer: operand value and availability
  procedure route(
    sel : in std_logic_vector(2 downto 0);
    n, e, s, w, loc, self, immv : in signed(DATA_W - 1 downto 0);
    vn, ve, vs, vw, vloc, vself : in std_logic;
    val : out signed(DATA_W - 1 downto 0);
    ok  : out std_logic) is
  begin
    ok := '1';
    case sel is
      when SRC_N    => val := n;   ok := vn;
      when SRC_E    => val := e;   ok := ve;
      when SRC_S    => val := s;   ok := vs;
      when SRC_W    => val := w;   ok := vw;
      when SRC_LOC  => val := loc; ok := vloc;
      when SRC_SELF => val := self;   -- always available (0 after clear)
      when SRC_IMM  => val := immv;
      when others   => val := (others => '0');
    end case;
  end procedure;

  function shift_op(x : signed; sh : std_logic_vector(SHIFT_W - 1 downto 0)) return signed is
    variable n : natural := to_integer(unsigned(sh(SHIFT_W - 2 downto 0)));
  begin
    if sh(SHIFT_W - 1) = '1' then
      return shift_right(x, n);   -- arithmetic right shift
    else
      return shift_left(x, n);
    end if;
  end function;

begin

  ---------------------------------------------------------------------------
  -- configuration memory (write port + asynchronous read of active context)
  ---------------------------------------------------------------------------
  p_cfg : process (clk)
  begin
    if rising_edge(clk) then
      if cfg_we = '1' then
        cfg_mem(cfg_addr) <= cfg_data;
      end if;
    end if;
  end process;

  cfg <= cfg_mem(cfg_ctx);

  oneshot <= cfg(CFG_W - 1);
  op      <= cfg(CFG_W - 2 downto CFG_W - 4);
  sel_a   <= cfg(CFG_W - 5 downto CFG_W - 7);
  sel_b   <= cfg(CFG_W - 8 downto CFG_W - 10);
  sh_a    <= cfg(CFG_W - 11 downto CFG_W - 15);
  sh_b    <= cfg(CFG_W - 16 downto CFG_W - 20);
  imm     <= signed(cfg(DATA_W - 1 downto 0));

  ---------------------------------------------------------------------------
  -- operand routing multiplexers
  ---------------------------------------------------------------------------
  p_mux : process (all)
    variable va, vb : signed(DATA_W - 1 downto 0);
    variable oa, ob : std_logic;
  begin
    route(sel_a, signed(in_n), signed(in_e), signed(in_s), signed(in_w),
          signed(in_loc), out_reg, imm,
          v_n, v_e, v_s, v_w, v_loc, valid_r, va, oa);
    route(sel_b, signed(in_n), signed(in_e), signed(in_s), signed(in_w),
          signed(in_loc), out_reg, imm,
          v_n, v_e, v_s, v_w, v_loc, valid_r, vb, ob);
    opnd_a <= va; ok_a <= oa;
    opnd_b <= vb; ok_b <= ob;
  end process;

  sa <= shift_op(opnd_a, sh_a);
  sb <= shift_op(opnd_b, sh_b);

  ---------------------------------------------------------------------------
  -- ALU
  ---------------------------------------------------------------------------
  p_alu : process (all)
    variable prod : signed(2 * DATA_W - 1 downto 0);
  begin
    prod   := sa * sb;
    result <= (others => '0');
    case op is
      when OP_PASS => result <= sa;
      when OP_ADD  => result <= sa + sb;
      when OP_SUB  => result <= sa - sb;
      when OP_MUL  => result <= prod(DATA_W - 1 downto 0);
      when others  => null;
    end case;
  end process;

  ---------------------------------------------------------------------------
  -- firing condition
  ---------------------------------------------------------------------------
  fire <= '1' when op /= OP_NOP
                   and ok_a = '1'
                   and (ok_b = '1' or op = OP_PASS)
                   and not (oneshot = '1' and done_r = '1')
          else '0';

  ---------------------------------------------------------------------------
  -- output register and status flags
  ---------------------------------------------------------------------------
  p_out : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' or clear = '1' then
        valid_r <= '0';
        done_r  <= '0';
        out_reg <= (others => '0');
      elsif fire = '1' then
        out_reg <= result;
        valid_r <= '1';
        done_r  <= '1';
      end if;
    end if;
  end process;

  out_data  <= std_logic_vector(out_reg);
  out_valid <= valid_r;
  fired     <= fire;

end architecture rtl;
