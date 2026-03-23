--------------------------------------------------------------------------------
-- Title       : I2C Slave Hardware Test Top-Level
-- Project     : I2C Slave Implementation
-- File        : test_i2c_slave.vhd
-- Author      : FPGA Designer
-- Created     : March 22, 2026
-- Description : Top-level wrapper for hardware verification of i2c_slave +
--               register_file on the Microsemi IGLOO Nano Starter Kit
--               (AGLN250V2-VQ100).
--
-- Pin assignments:
--   CLK   : pin 15  - 20 MHz external oscillator
--   RST_N : pin 20  - BTN1 (active-low: press to reset)
--   SCL   : pin 33  - I2C clock input from protocol analyser
--   SDA   : pin 34  - I2C data, bidirectional open-drain
--   LED1  : pin 35  - i2c_active (high while a transaction is in progress)
--   LED2  : pin 36  - write activity indicator (stretched 500 ms pulse)
--   LED3  : pin 40  - control_reg bit 5
--   LED4  : pin 41  - control_reg bit 4
--   LED5  : pin 42  - control_reg bit 3
--   LED6  : pin 43  - control_reg bit 2
--   LED7  : pin 44  - control_reg bit 1
--   LED8  : pin 45  - control_reg bit 0
--
-- I2C slave address : 0x50 ("1010000")
-- Register map (see hdl/register_file.vhd):
--   0x00  Device ID     (RO) = 0xA5
--   0x01  Control       (RW) -> visible on LED3-LED8
--   0x02  Status        (RO) -> reflects {BTN4, BTN3, BTN2, "00000"}
--   0x03  Version       (RO) = 0x01
--   0x04  Data reg 0    (RW)
--   0x05  Data reg 1    (RW)
--   0x06  Data reg 2    (RW)
--   0x07  Data reg 3    (RW)
--
-- SDA open-drain: an external pull-up resistor (typically 4.7 kΩ) to 3.3 V
-- is required on the SDA line.  The FPGA only drives SDA low; when idle or
-- sending a '1' bit SDA is released (tristate) and the pull-up provides VCC.
--
-- Verification procedure with a protocol analyser:
--   1. Power the board and connect the analyser to SCL (pin 33) and SDA (pin 34).
--   2. Read 0x00  -> expect 0xA5
--   3. Read 0x03  -> expect 0x01
--   4. Write 0x01, 0xAB  -> LED3-8 should show 0b101011
--   5. Read 0x01  -> expect 0xAB
--   6. Press BTN2/BTN3/BTN4, read 0x02 -> expect bits [7:5] to reflect buttons
--   7. Write 0x04..0x07 (burst), then burst-read back
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity test_i2c_slave is
    port (
        -- System
        clk     : in    std_logic;                      -- pin 15, 20 MHz

        -- User inputs
        rst_n   : in    std_logic;                      -- pin 20, BTN1
        btn2    : in    std_logic;                      -- pin 21, BTN2
        btn3    : in    std_logic;                      -- pin 22, BTN3
        btn4    : in    std_logic;                      -- pin 23, BTN4

        -- I2C bus
        scl     : in    std_logic;                      -- pin 33, SCL input
        sda     : inout std_logic;                      -- pin 34, SDA open-drain
        dbg_scl : out   std_logic;                      -- pin 57
        dbg_sda : out   std_logic;                      -- pin 76

        -- Status LEDs (active high)
        led1    : out   std_logic;                      -- pin 35
        led2    : out   std_logic;                      -- pin 36
        led3    : out   std_logic;                      -- pin 40
        led4    : out   std_logic;                      -- pin 41
        led5    : out   std_logic;                      -- pin 42
        led6    : out   std_logic;                      -- pin 43
        led7    : out   std_logic;                      -- pin 44
        led8    : out   std_logic                       -- pin 45
    );
end entity test_i2c_slave;

architecture rtl of test_i2c_slave is

    ---------------------------------------------------------------------------
    -- I2C slave <-> register file internal bus
    ---------------------------------------------------------------------------
    signal sda_out_s    : std_logic;
    signal sda_oe_s     : std_logic;
    signal sda_in_s     : std_logic;

    signal reg_addr     : std_logic_vector(7 downto 0);
    signal reg_wr_data  : std_logic_vector(7 downto 0);
    signal reg_rd_data  : std_logic_vector(7 downto 0);
    signal reg_write    : std_logic;
    signal reg_read     : std_logic;

    -- Application interface from register_file
    signal control_reg  : std_logic_vector(7 downto 0);
    signal status_reg   : std_logic_vector(7 downto 0);
    signal data_reg0    : std_logic_vector(7 downto 0);
    signal data_reg1    : std_logic_vector(7 downto 0);
    signal data_reg2    : std_logic_vector(7 downto 0);
    signal data_reg3    : std_logic_vector(7 downto 0);

    signal i2c_active   : std_logic;
    signal i2c_error    : std_logic;

    ---------------------------------------------------------------------------
    -- Write-activity LED stretcher
    -- At 20 MHz, 500 ms = 10_000_000 counts  (24-bit counter)
    ---------------------------------------------------------------------------
    constant STRETCH_COUNT : natural := 10_000_000;
    signal   wr_stretch    : natural range 0 to STRETCH_COUNT := 0;
    signal   wr_led        : std_logic := '0';

begin

    ---------------------------------------------------------------------------
    -- SDA open-drain tristate
    -- Drive SDA low only when slave requests it; otherwise release (Hi-Z).
    -- External 4.7 kΩ pull-up to 3.3 V provides the logic-high level.
    ---------------------------------------------------------------------------
    sda      <= '0' when (sda_oe_s = '1' and sda_out_s = '0') else 'Z';
    sda_in_s <= sda;

    dbg_scl  <= scl;
    dbg_sda  <= sda;

    ---------------------------------------------------------------------------
    -- Status register input: upper 3 bits mirror BTN2/BTN3/BTN4.
    -- Buttons are active-low on the Nano Starter Kit, so invert them so
    -- that a pressed button shows as '1' in the status register.
    ---------------------------------------------------------------------------
    status_reg <= (not btn4) & (not btn3) & (not btn2) & "00000";

    ---------------------------------------------------------------------------
    -- i2c_slave
    ---------------------------------------------------------------------------
    u_i2c_slave : entity work.i2c_slave
        generic map (
            SLAVE_ADDR => "1010000",    -- 0x50
            NUM_REGS   => 16
        )
        port map (
            clk          => clk,
            rst_n        => rst_n,
            scl          => scl,
            sda_in       => sda_in_s,
            sda_out      => sda_out_s,
            sda_oe       => sda_oe_s,
            reg_addr     => reg_addr,
            reg_data_out => reg_wr_data,
            reg_data_in  => reg_rd_data,
            reg_write    => reg_write,
            reg_read     => reg_read,
            i2c_active   => i2c_active,
            error        => i2c_error
        );

    ---------------------------------------------------------------------------
    -- register_file
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
    -- Write activity LED stretcher
    -- Pulses wr_led for ~500 ms every time a register write occurs so the
    -- LED is visible to the eye (reg_write is only one clock wide).
    ---------------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            wr_stretch <= 0;
            wr_led     <= '0';
        elsif rising_edge(clk) then
            if reg_write = '1' then
                wr_stretch <= STRETCH_COUNT;
                wr_led     <= '1';
            elsif wr_stretch > 0 then
                wr_stretch <= wr_stretch - 1;
            else
                wr_led <= '0';
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- LED assignments
    -- LED1 : I2C transaction in progress
    -- LED2 : Write activity (stretched)
    -- LED3-8 : control_reg[5:0] �?? shows the last value written to 0x01
    ---------------------------------------------------------------------------
    led1 <= i2c_active;
    led2 <= wr_led;
    led3 <= control_reg(5);
    led4 <= control_reg(4);
    led5 <= control_reg(3);
    led6 <= control_reg(2);
    led7 <= control_reg(1);
    led8 <= control_reg(0);

end architecture rtl;
