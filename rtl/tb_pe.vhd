-------------------------------------------------------------------------------
-- tb_pe.vhd : self-checking testbench. Two PEs in a row:
--   PE0 (west) : y0 = (loc << 2) + (-1 * imm)   -> SUB: (loc<<2) - imm
--   PE1 (east) : y1 = (W >> 1) + loc             -> uses PE0 as west neighbour
-- plus accumulate test on PE0 with SRC_SELF, and a NOP test.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pe_pkg.all;

entity tb_pe is
end entity;

architecture sim of tb_pe is
  constant W : natural := 16;
  constant Z : std_logic_vector(W - 1 downto 0) := (others => '0');

  signal clk : std_logic := '0';
  signal rst, clear : std_logic := '1';
  signal done : boolean := false;

  signal we0, we1 : std_logic := '0';
  signal addr0, addr1, ctx : natural range 0 to 3 := 0;
  signal cd0, cd1 : std_logic_vector(cfg_width(W) - 1 downto 0) := (others => '0');

  signal loc0, loc1, o0, o1 : std_logic_vector(W - 1 downto 0) := (others => '0');
  signal vl0, vl1, ov0, ov1, f0, f1 : std_logic := '0';

  function s16(i : integer) return std_logic_vector is
  begin
    return std_logic_vector(to_signed(i, W));
  end function;

  procedure check(name : string; got : std_logic_vector; exp : integer) is
  begin
    assert signed(got) = to_signed(exp, W)
      report name & ": got " & integer'image(to_integer(signed(got))) &
             " expected " & integer'image(exp) severity failure;
    report name & " OK (" & integer'image(exp) & ")";
  end procedure;
begin
  clk <= not clk after 5 ns when not done;

  pe0 : entity work.pe
    generic map (DATA_W => W, CFG_DEPTH => 4)
    port map (clk => clk, rst => rst, cfg_we => we0, cfg_addr => addr0,
              cfg_data => cd0, cfg_ctx => ctx, clear => clear,
              in_n => Z, in_e => o1, in_s => Z, in_w => Z,
              v_n => '0', v_e => ov1, v_s => '0', v_w => '0',
              in_loc => loc0, v_loc => vl0,
              out_data => o0, out_valid => ov0, fired => f0);

  pe1 : entity work.pe
    generic map (DATA_W => W, CFG_DEPTH => 4)
    port map (clk => clk, rst => rst, cfg_we => we1, cfg_addr => addr1,
              cfg_data => cd1, cfg_ctx => ctx, clear => clear,
              in_n => Z, in_e => Z, in_s => Z, in_w => o0,
              v_n => '0', v_e => '0', v_s => '0', v_w => ov0,
              in_loc => loc1, v_loc => vl1,
              out_data => o1, out_valid => ov1, fired => f1);

  stim : process
  begin
    wait for 22 ns;
    rst <= '0'; clear <= '0';
    wait until rising_edge(clk);

    -- context 0: PE0: (loc<<2) - imm(5) ; PE1: (W>>1) + loc
    cd0   <= make_cfg(W, '1', OP_SUB, SRC_LOC, SRC_IMM, "00010", "00000", s16(5));
    cd1   <= make_cfg(W, '1', OP_ADD, SRC_W,   SRC_LOC, "10001", "00000", s16(0));
    we0 <= '1'; we1 <= '1'; addr0 <= 0; addr1 <= 0;
    wait until rising_edge(clk);
    -- context 1: PE0 accumulates: self + loc (not one-shot)
    cd0   <= make_cfg(W, '0', OP_ADD, SRC_SELF, SRC_LOC, "00000", "00000", s16(0));
    addr0 <= 1; we1 <= '0';
    wait until rising_edge(clk);
    we0 <= '0';
    ctx <= 0;
    wait until rising_edge(clk);

    -- Test 1: nothing fires until operands valid
    wait until rising_edge(clk);
    assert ov0 = '0' and ov1 = '0' report "fired without valid operands" severity failure;

    loc0 <= s16(10); vl0 <= '1';       -- PE0 = 10*4 - 5 = 35
    loc1 <= s16(7);  vl1 <= '1';       -- PE1 = (35>>1) + 7 = 17+7 = 24
    wait until rising_edge(clk);       -- PE0 fires at this edge
    wait for 1 ns;
    check("PE0 sub-shift", o0, 35);
    assert ov0 = '1' report "PE0 valid missing" severity failure;
    wait until rising_edge(clk);       -- PE1 fires (sees PE0 valid)
    wait for 1 ns;
    check("PE1 add-shift via W", o1, 24);

    -- one-shot: change input, result must hold
    loc0 <= s16(99);
    wait until rising_edge(clk); wait for 1 ns;
    check("PE0 one-shot holds", o0, 35);

    -- Test 2: clear and accumulate on context 1
    clear <= '1'; wait until rising_edge(clk); clear <= '0';
    ctx <= 1; vl0 <= '1'; loc0 <= s16(3);
    wait until rising_edge(clk); wait for 1 ns;
    check("acc 1", o0, 3);
    wait until rising_edge(clk); wait for 1 ns;
    check("acc 2", o0, 6);
    wait until rising_edge(clk); wait for 1 ns;
    check("acc 3", o0, 9);

    report "ALL TESTS PASSED";
    done <= true;
    wait;
  end process;
end architecture;
