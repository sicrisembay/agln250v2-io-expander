--------------------------------------------------------------------------------
-- Title       : I2C System Testbench
-- Project     : I2C Slave Implementation
-- File        : tb_i2c_system.vhd
-- Author      : FPGA Designer
-- Created     : March 20, 2026
-- Description : Testbench for i2c_slave + register_file system.
--               Implements a behavioural I2C master model and exercises:
--                 - Single-byte register write
--                 - Multi-byte sequential write (auto-increment)
--                 - Single-byte register read (write ptr + repeated start)
--                 - Multi-byte sequential read
--                 - Read-only register protection (ID, Version)
--                 - Status register live update
--                 - Wrong-address NACK
--
-- Clock:  50 MHz system clock (20 ns)
-- I2C:   100 kHz (SCL half-period = 250 system clocks = 5 us)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_i2c_system is
end entity tb_i2c_system;

architecture sim of tb_i2c_system is

    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    constant CLK_PERIOD    : time    := 20 ns;       -- 50 MHz
    constant SCL_HALF      : time    := 5 us;        -- 100 kHz I2C
    constant SLAVE_ADDR_C  : std_logic_vector(6 downto 0) := "1010000"; -- 0x50
    constant WRONG_ADDR_C  : std_logic_vector(6 downto 0) := "0110001"; -- 0x31

    ---------------------------------------------------------------------------
    -- DUT signals
    ---------------------------------------------------------------------------
    signal clk          : std_logic := '0';
    signal rst_n        : std_logic := '0';

    -- I2C bus (wired-AND model: master and slave both drive open-drain)
    signal scl_master   : std_logic := '1';   -- master drives SCL
    signal sda_master   : std_logic := '1';   -- master open-drain SDA
    signal sda_slave    : std_logic;          -- slave output
    signal sda_oe_slave : std_logic;          -- slave output enable
    signal sda_bus      : std_logic;          -- wired-AND bus

    -- Register bus (between i2c_slave and register_file)
    signal reg_addr     : std_logic_vector(7 downto 0);
    signal reg_wr_data  : std_logic_vector(7 downto 0);
    signal reg_rd_data  : std_logic_vector(7 downto 0);
    signal reg_write    : std_logic;
    signal reg_read     : std_logic;

    -- register_file application interface
    signal control_reg  : std_logic_vector(7 downto 0);
    signal status_reg   : std_logic_vector(7 downto 0) := x"00";
    signal data_reg0    : std_logic_vector(7 downto 0);
    signal data_reg1    : std_logic_vector(7 downto 0);
    signal data_reg2    : std_logic_vector(7 downto 0);
    signal data_reg3    : std_logic_vector(7 downto 0);

    -- i2c_slave status
    signal i2c_active   : std_logic;
    signal i2c_error    : std_logic;

    ---------------------------------------------------------------------------
    -- Test tracking
    ---------------------------------------------------------------------------
    signal pass_count   : integer := 0;
    signal fail_count   : integer := 0;

    ---------------------------------------------------------------------------
    -- Wired-AND bus: SDA is low if any driver pulls it low
    ---------------------------------------------------------------------------
    signal sda_slave_driven : std_logic;

begin

    ---------------------------------------------------------------------------
    -- Clock generation
    ---------------------------------------------------------------------------
    clk <= not clk after CLK_PERIOD / 2;

    ---------------------------------------------------------------------------
    -- Wired-AND SDA bus
    -- Slave drives sda_bus low when sda_oe = '1' and sda_out = '0'
    ---------------------------------------------------------------------------
    sda_slave_driven <= sda_slave when sda_oe_slave = '1' else '1';
    sda_bus <= sda_master and sda_slave_driven;

    ---------------------------------------------------------------------------
    -- DUT: i2c_slave
    ---------------------------------------------------------------------------
    u_i2c_slave : entity work.i2c_slave
        generic map (
            SLAVE_ADDR => SLAVE_ADDR_C,
            NUM_REGS   => 16
        )
        port map (
            clk          => clk,
            rst_n        => rst_n,
            scl          => scl_master,
            sda_in       => sda_bus,
            sda_out      => sda_slave,
            sda_oe       => sda_oe_slave,
            reg_addr     => reg_addr,
            reg_data_out => reg_wr_data,
            reg_data_in  => reg_rd_data,
            reg_write    => reg_write,
            reg_read     => reg_read,
            i2c_active   => i2c_active,
            error        => i2c_error
        );

    ---------------------------------------------------------------------------
    -- DUT: register_file
    ---------------------------------------------------------------------------
    u_register_file : entity work.register_file
        generic map (
            NUM_REGS => 16
        )
        port map (
            clk          => clk,
            rst_n        => rst_n,
            reg_addr     => reg_addr,
            reg_data_in  => reg_wr_data,
            reg_data_out => reg_rd_data,
            reg_write    => reg_write,
            reg_read     => reg_read,
            control_reg  => control_reg,
            status_reg   => status_reg,
            data_reg0    => data_reg0,
            data_reg1    => data_reg1,
            data_reg2    => data_reg2,
            data_reg3    => data_reg3
        );

    ---------------------------------------------------------------------------
    -- I2C Master Model
    -- All procedures are defined as shared subprograms via the process below.
    -- They operate on scl_master and sda_master signals.
    ---------------------------------------------------------------------------
    stimulus : process

        -- Wait for a number of SCL quarter-periods (used for bit timing)
        procedure i2c_delay(halves : integer := 1) is
        begin
            for i in 1 to halves loop
                wait for SCL_HALF;
            end loop;
        end procedure;

        -- Generate I2C START condition (SDA falls while SCL high)
        procedure i2c_start is
        begin
            scl_master <= '1';
            sda_master <= '1';
            wait for SCL_HALF;
            sda_master <= '0';   -- SDA falls while SCL high
            wait for SCL_HALF;
            scl_master <= '0';   -- SCL goes low to begin first bit
            wait for SCL_HALF;
        end procedure;

        -- Generate I2C REPEATED START condition
        procedure i2c_repeated_start is
        begin
            sda_master <= '1';
            wait for SCL_HALF / 2;
            scl_master <= '1';
            wait for SCL_HALF;
            sda_master <= '0';   -- SDA falls while SCL high
            wait for SCL_HALF;
            scl_master <= '0';
            wait for SCL_HALF;
        end procedure;

        -- Generate I2C STOP condition (SDA rises while SCL high)
        procedure i2c_stop is
        begin
            sda_master <= '0';
            wait for SCL_HALF / 2;
            scl_master <= '1';
            wait for SCL_HALF;
            sda_master <= '1';   -- SDA rises while SCL high
            wait for SCL_HALF;
        end procedure;

        -- Send one bit on SDA; SCL starts and ends low
        procedure i2c_send_bit(b : std_logic) is
        begin
            sda_master <= b;
            wait for SCL_HALF;
            scl_master <= '1';
            wait for SCL_HALF;
            scl_master <= '0';
            wait for SCL_HALF;
        end procedure;

        -- Send one byte MSB first; returns received ACK bit
        -- ack_received = '0' means ACK, '1' means NACK
        procedure i2c_send_byte(
            data         : in  std_logic_vector(7 downto 0);
            ack_received : out std_logic
        ) is
            variable ack : std_logic;
        begin
            for i in 7 downto 0 loop
                i2c_send_bit(data(i));
            end loop;
            -- Release SDA for ACK
            sda_master <= '1';
            wait for SCL_HALF;
            scl_master <= '1';
            wait for SCL_HALF;
            ack := sda_bus;      -- sample ACK while SCL high
            scl_master <= '0';
            wait for SCL_HALF;
            ack_received := ack;
        end procedure;

        -- Receive one byte MSB first; master sends ACK/NACK at the end
        -- send_ack = '1' to ACK (continue), '0' to NACK (stop)
        procedure i2c_recv_byte(
            data     : out std_logic_vector(7 downto 0);
            send_ack : in  std_logic
        ) is
            variable rx : std_logic_vector(7 downto 0);
            variable b  : std_logic;
        begin
            sda_master <= '1';   -- release SDA
            for i in 7 downto 0 loop
                wait for SCL_HALF;
                scl_master <= '1';
                wait for SCL_HALF;
                rx(i) := sda_bus;   -- sample on SCL high
                scl_master <= '0';
                wait for SCL_HALF;
            end loop;
            -- Send ACK or NACK
            if send_ack = '1' then
                sda_master <= '0';  -- ACK: pull low
            else
                sda_master <= '1';  -- NACK: release
            end if;
            wait for SCL_HALF;
            scl_master <= '1';
            wait for SCL_HALF;
            scl_master <= '0';
            wait for SCL_HALF;
            sda_master <= '1';
            data := rx;
        end procedure;

        -- High-level: Write one or more bytes to a register address
        -- Sends: START | addr+W | ACK | reg | ACK | data[0] | ACK | ... | STOP
        procedure i2c_write(
            reg    : in std_logic_vector(7 downto 0);
            data   : in std_logic_vector(7 downto 0)
        ) is
            variable ack : std_logic;
        begin
            i2c_start;
            i2c_send_byte(SLAVE_ADDR_C & '0', ack);
            assert ack = '0' report "WRITE: no ACK on address" severity warning;
            i2c_send_byte(reg, ack);
            assert ack = '0' report "WRITE: no ACK on reg addr" severity warning;
            i2c_send_byte(data, ack);
            assert ack = '0' report "WRITE: no ACK on data" severity warning;
            i2c_stop;
        end procedure;

        -- High-level: Write multiple consecutive bytes (auto-increment)
        procedure i2c_write_burst(
            reg    : in std_logic_vector(7 downto 0);
            d0     : in std_logic_vector(7 downto 0);
            d1     : in std_logic_vector(7 downto 0);
            d2     : in std_logic_vector(7 downto 0);
            d3     : in std_logic_vector(7 downto 0)
        ) is
            variable ack : std_logic;
        begin
            i2c_start;
            i2c_send_byte(SLAVE_ADDR_C & '0', ack);
            i2c_send_byte(reg, ack);
            i2c_send_byte(d0, ack);
            i2c_send_byte(d1, ack);
            i2c_send_byte(d2, ack);
            i2c_send_byte(d3, ack);
            i2c_stop;
        end procedure;

        -- High-level: Read one byte from a register address
        -- Sends: START | addr+W | ACK | reg | ACK | RST | addr+R | ACK | data | NACK | STOP
        procedure i2c_read(
            reg    : in  std_logic_vector(7 downto 0);
            data   : out std_logic_vector(7 downto 0)
        ) is
            variable ack : std_logic;
            variable rx  : std_logic_vector(7 downto 0);
        begin
            i2c_start;
            i2c_send_byte(SLAVE_ADDR_C & '0', ack);
            assert ack = '0' report "READ(W): no ACK on address" severity warning;
            i2c_send_byte(reg, ack);
            assert ack = '0' report "READ(W): no ACK on reg addr" severity warning;
            i2c_repeated_start;
            i2c_send_byte(SLAVE_ADDR_C & '1', ack);
            assert ack = '0' report "READ(R): no ACK on address" severity warning;
            i2c_recv_byte(rx, '0');  -- NACK = last byte
            i2c_stop;
            data := rx;
        end procedure;

        -- High-level: Read multiple consecutive bytes
        procedure i2c_read_burst(
            reg    : in  std_logic_vector(7 downto 0);
            d0     : out std_logic_vector(7 downto 0);
            d1     : out std_logic_vector(7 downto 0);
            d2     : out std_logic_vector(7 downto 0);
            d3     : out std_logic_vector(7 downto 0)
        ) is
            variable ack : std_logic;
            variable rx0, rx1, rx2, rx3 : std_logic_vector(7 downto 0);
        begin
            i2c_start;
            i2c_send_byte(SLAVE_ADDR_C & '0', ack);
            i2c_send_byte(reg, ack);
            i2c_repeated_start;
            i2c_send_byte(SLAVE_ADDR_C & '1', ack);
            i2c_recv_byte(rx0, '1');   -- ACK: more to come
            i2c_recv_byte(rx1, '1');
            i2c_recv_byte(rx2, '1');
            i2c_recv_byte(rx3, '0');   -- NACK: last byte
            i2c_stop;
            d0 := rx0; d1 := rx1; d2 := rx2; d3 := rx3;
        end procedure;

        -- Check helper: reports pass/fail
        procedure check(
            msg      : string;
            got      : std_logic_vector(7 downto 0);
            expected : std_logic_vector(7 downto 0)
        ) is
        begin
            if got = expected then
                report "[PASS] " & msg &
                       "  got=0x" & to_hstring(got) severity warning;
                pass_count <= pass_count + 1;
            else
                report "[FAIL] " & msg &
                       "  got=0x" & to_hstring(got) &
                       "  expected=0x" & to_hstring(expected) severity error;
                fail_count <= fail_count + 1;
            end if;
        end procedure;

        variable rx      : std_logic_vector(7 downto 0);
        variable rx0, rx1, rx2, rx3 : std_logic_vector(7 downto 0);
        variable ack     : std_logic;

    begin
        -----------------------------------------------------------------------
        -- Reset
        -----------------------------------------------------------------------
        scl_master <= '1';
        sda_master <= '1';
        rst_n      <= '0';
        wait for CLK_PERIOD * 10;
        rst_n <= '1';
        wait for CLK_PERIOD * 5;

        -----------------------------------------------------------------------
        -- TEST 1: Read ID register (0x00) — should return 0xA5
        -----------------------------------------------------------------------
        report "--- T1: Read ID register (0x00) ---" severity warning;
        i2c_read(x"00", rx);
        wait for CLK_PERIOD * 4;
        check("ID register", rx, x"A5");

        -----------------------------------------------------------------------
        -- TEST 2: Read Version register (0x03) — should return 0x01
        -----------------------------------------------------------------------
        report "--- T2: Read Version register (0x03) ---" severity warning;
        i2c_read(x"03", rx);
        wait for CLK_PERIOD * 4;
        check("Version register", rx, x"01");

        -----------------------------------------------------------------------
        -- TEST 3: Write control register (0x01) and read back
        -----------------------------------------------------------------------
        report "--- T3: Write control register (0x01) = 0xAB ---" severity warning;
        i2c_write(x"01", x"AB");
        wait for CLK_PERIOD * 4;
        -- Verify via application port
        check("control_reg port after write", control_reg, x"AB");
        -- Verify via I2C read
        i2c_read(x"01", rx);
        wait for CLK_PERIOD * 4;
        check("Control register I2C read", rx, x"AB");

        -----------------------------------------------------------------------
        -- TEST 4: Write data registers 0x04..0x07 (burst) and read back
        -----------------------------------------------------------------------
        report "--- T4: Burst write data registers 0x04..0x07 ---" severity warning;
        i2c_write_burst(x"04", x"11", x"22", x"33", x"44");
        wait for CLK_PERIOD * 4;
        check("data_reg0 port", data_reg0, x"11");
        check("data_reg1 port", data_reg1, x"22");
        check("data_reg2 port", data_reg2, x"33");
        check("data_reg3 port", data_reg3, x"44");

        -----------------------------------------------------------------------
        -- TEST 5: Burst read back data registers 0x04..0x07
        -----------------------------------------------------------------------
        report "--- T5: Burst read data registers 0x04..0x07 ---" severity warning;
        i2c_read_burst(x"04", rx0, rx1, rx2, rx3);
        wait for CLK_PERIOD * 4;
        check("data_reg0 I2C read", rx0, x"11");
        check("data_reg1 I2C read", rx1, x"22");
        check("data_reg2 I2C read", rx2, x"33");
        check("data_reg3 I2C read", rx3, x"44");

        -----------------------------------------------------------------------
        -- TEST 6: Write attempt to read-only ID register (0x00)
        --         Value should stay 0xA5
        -----------------------------------------------------------------------
        report "--- T6: Write to read-only ID register (0x00) ---" severity warning;
        i2c_write(x"00", x"FF");
        wait for CLK_PERIOD * 4;
        i2c_read(x"00", rx);
        wait for CLK_PERIOD * 4;
        check("ID register still 0xA5", rx, x"A5");

        -----------------------------------------------------------------------
        -- TEST 7: Status register live update
        --         Write a value to status_reg port; read via I2C
        -----------------------------------------------------------------------
        report "--- T7: Status register live update ---" severity warning;
        status_reg <= x"C3";
        wait for CLK_PERIOD * 4;  -- allow register to latch
        i2c_read(x"02", rx);
        wait for CLK_PERIOD * 4;
        check("Status register = 0xC3", rx, x"C3");
        -- Change status and verify again
        status_reg <= x"5A";
        wait for CLK_PERIOD * 4;
        i2c_read(x"02", rx);
        wait for CLK_PERIOD * 4;
        check("Status register = 0x5A", rx, x"5A");

        -----------------------------------------------------------------------
        -- TEST 8: Wrong I2C address — slave should NACK
        -----------------------------------------------------------------------
        report "--- T8: Wrong address NACK test ---" severity warning;
        i2c_start;
        i2c_send_byte(WRONG_ADDR_C & '0', ack);
        if ack = '1' then
            report "[PASS] Wrong address correctly NACKed" severity warning;
            pass_count <= pass_count + 1;
        else
            report "[FAIL] Wrong address was ACKed - should have been NACKed" severity error;
            fail_count <= fail_count + 1;
        end if;
        i2c_stop;
        wait for CLK_PERIOD * 4;

        -----------------------------------------------------------------------
        -- TEST 9: Overwrite data registers with new values, verify update
        -----------------------------------------------------------------------
        report "--- T9: Overwrite data registers ---" severity warning;
        i2c_write(x"04", x"DE");
        wait for CLK_PERIOD * 4;
        i2c_write(x"05", x"AD");
        wait for CLK_PERIOD * 4;
        check("data_reg0 overwrite", data_reg0, x"DE");
        check("data_reg1 overwrite", data_reg1, x"AD");

        -----------------------------------------------------------------------
        -- Summary
        -----------------------------------------------------------------------
        wait for SCL_HALF * 2;
        report "========================================" severity warning;
        report "SIMULATION COMPLETE" severity warning;
        report "PASS: " & integer'image(pass_count) severity warning;
        report "FAIL: " & integer'image(fail_count) severity warning;
        report "========================================" severity warning;

        if fail_count = 0 then
            report "ALL TESTS PASSED" severity warning;
        else
            report "SOME TESTS FAILED" severity failure;
        end if;

        wait;
    end process;

end architecture sim;
