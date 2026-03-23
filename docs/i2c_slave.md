# I2C Slave Controller

**File:** `hdl/i2c_slave.vhd`  
**Author:** FPGA Designer  
**Created:** July 27, 2025  
**Project:** I2C Slave Implementation (AGLN250V2 IO Expander)

---

## Overview

`i2c_slave` is a register-based I2C slave controller implemented in VHDL for the Microsemi AGLN250V2 FPGA. It supports standard 7-bit I2C addressing and provides a register bus interface that connects to an external register file. The controller handles the full I2C protocol including start/stop condition detection, address matching, data reception, and data transmission with automatic register address incrementing.

---

## Generics

| Name         | Type                          | Default     | Description                                  |
|--------------|-------------------------------|-------------|----------------------------------------------|
| `SLAVE_ADDR` | `std_logic_vector(6 downto 0)` | `"1010000"` | 7-bit I2C slave address (0x50)               |
| `NUM_REGS`   | `integer`                     | `16`        | Number of internal registers (informational) |

---

## Port Description

### System Signals

| Port    | Direction | Width | Description                 |
|---------|-----------|-------|-----------------------------|
| `clk`   | in        | 1     | System clock                |
| `rst_n` | in        | 1     | Active-low synchronous reset |

### I2C Interface

The SDA bus is split into separate input, output, and output-enable signals to allow external tri-state buffer control.

| Port      | Direction | Width | Description                              |
|-----------|-----------|-------|------------------------------------------|
| `scl`     | in        | 1     | I2C clock line                           |
| `sda_in`  | in        | 1     | I2C data line — input path               |
| `sda_out` | out       | 1     | I2C data line — output path              |
| `sda_oe`  | out       | 1     | SDA output enable (active high)          |

**External tri-state connection example:**
```vhdl
sda <= sda_out when sda_oe = '1' else 'Z';
sda_in <= sda;
```

### Register Interface

These signals connect directly to the `register_file` module.

| Port           | Direction | Width | Description                              |
|----------------|-----------|-------|------------------------------------------|
| `reg_addr`     | out       | 8     | Current register address being accessed  |
| `reg_data_out` | out       | 8     | Data to write into the register file     |
| `reg_data_in`  | in        | 8     | Data read from the register file         |
| `reg_write`    | out       | 1     | Register write strobe (1 clock pulse)    |
| `reg_read`     | out       | 1     | Register read strobe (1 clock pulse)     |

### Status Signals

| Port         | Direction | Width | Description                                      |
|--------------|-----------|-------|--------------------------------------------------|
| `i2c_active` | out       | 1     | High when an I2C transaction is in progress      |
| `error`      | out       | 1     | High when an unexpected start/stop is detected   |

---

## State Machine

The controller implements a 10-state Moore FSM.

```
                    ┌──────────────────────────────────────────────────┐
                    │  stop_cond (any state)                           │
                    ▼                                                  │
              ┌──────────┐                                             │
    ──reset──►│   IDLE   │◄──NACK / addr mismatch                     │
              └────┬─────┘                                             │
                   │ start_cond                                        │
                   ▼                                                   │
          ┌─────────────────┐                                          │
          │ START_DETECTED  │                                          │
          └────────┬────────┘                                          │
                   │ scl_falling                                       │
                   ▼                                                   │
          ┌─────────────────┐                                          │
          │  ADDR_RECEIVE   │ (8 SCL rising edges)                     │
          └────────┬────────┘                                          │
                   │ 8th SCL falling                                   │
                   ▼                                                   │
          ┌─────────────────┐                                          │
          │   ADDR_ACK      │──────────────────────────────────────────┘
          └────────┬────────┘  (NACK if addr mismatch)
                   │
          ┌────────┴─────────┐
          │ rw_bit           │
     ='0' (write)       ='1' (read)
          │                  │
          ▼                  ▼
 ┌────────────────┐  ┌────────────────┐
 │  DATA_RECEIVE  │  │   DATA_SEND    │
 └───────┬────────┘  └───────┬────────┘
         │ 8th SCL falling   │ bit_count=7
         ▼                   ▼
 ┌────────────────┐  ┌─────────────────┐
 │   DATA_ACK     │  │ DATA_WAIT_ACK   │
 └───────┬────────┘  └────────┬────────┘
         │ auto-increment      │ ACK → scl_falling
         │                    ▼
         │           ┌─────────────────┐
         │           │ DATA_SEND_LOAD  │ (1-cycle staging)
         │           └────────┬────────┘
         │                    │ → DATA_SEND
         └────────────────────┘
```

### State Descriptions

| State             | Description                                                                                     |
|-------------------|-------------------------------------------------------------------------------------------------|
| `IDLE`            | Waiting for a start condition. All internal signals reset.                                      |
| `START_DETECTED`  | Start condition latched; waits for the first SCL falling edge to begin bit reception.           |
| `ADDR_RECEIVE`    | Shifts in 8 bits (7-bit address + R/W) on successive SCL rising edges. Transitions to `ADDR_ACK` on the **8th SCL falling edge** (after all bits are sampled) to avoid driving SDA low while SCL is still high. |
| `ADDR_ACK`        | Drives ACK (SDA low) if address matches `SLAVE_ADDR`, else drives NACK and returns to IDLE.    |
| `DATA_RECEIVE`    | Shifts in 8 data bits. The first received byte after address sets the internal register pointer; subsequent bytes are write data. Transitions to `DATA_ACK` on the **8th SCL falling edge** for the same reason as `ADDR_RECEIVE`. |
| `DATA_ACK`        | Drives ACK, increments register address (auto-increment), pulses `reg_write`.                  |
| `DATA_SEND`       | Shifts out 8 bits from `tx_shift_reg` MSB-first on successive SCL falling edges.               |
| `DATA_SEND_LOAD`  | One-cycle staging state entered after master ACK in `DATA_WAIT_ACK`. Latches `reg_data_in` into `tx_shift_reg` (combinatorial register-file read is already valid) then transitions immediately to `DATA_SEND`. |
| `DATA_WAIT_ACK`   | Waits for master ACK/NACK. ACK → increments address, defers to `DATA_SEND_LOAD` on SCL falling; NACK → returns to IDLE. |
| `STOP_DETECTED`   | Stop condition detected; immediately transitions to IDLE.                                       |

---

## Functional Description

### I2C Line Synchronization

Both `scl` and `sda_in` are passed through a 3-stage shift register synchronizer to prevent metastability. Edge detection signals (`scl_rising`, `scl_falling`, `sda_rising`, `sda_falling`) are derived from the synchronized values.

```
scl_sync[2:0]  ← { scl_sync[1:0], scl }

scl_falling = scl_sync[2] AND NOT scl_sync[1]
scl_rising  = NOT scl_sync[2] AND scl_sync[1]
```

### Start and Stop Condition Detection

```
start_cond = sda_falling when SCL is high   (SDA falls while SCL = 1)
stop_cond  = sda_rising  when SCL is high   (SDA rises while SCL = 1)
```

A `stop_cond` detected in any state immediately returns the FSM to `IDLE`.

### Address Phase

The 8 bits received during `ADDR_RECEIVE` are: `[A6:A0, R/W]`.  
- Bits `[7:1]` of the completed shift register are compared to `SLAVE_ADDR`.  
- Bit 0 (the R/W bit) is stored in `rw_bit` (`0` = write, `1` = read).

### Write Operation (R/W = 0)

1. Master sends slave address with R/W = 0.
2. Controller ACKs.
3. Master sends register address byte → stored in `current_reg_addr`.
4. Master sends data byte(s) → each byte is ACKed and `reg_write` is pulsed for one clock cycle.
5. `current_reg_addr` auto-increments after each byte.

### Read Operation (R/W = 1)

1. Master sends slave address with R/W = 1.
2. Controller ACKs and loads the first register value from `reg_data_in`.
3. Controller shifts out 8 bits on SDA.
4. If master sends ACK, the controller increments `current_reg_addr`, pulses `reg_read`, and loads the next register value.
5. If master sends NACK, the controller returns to IDLE.

### Register Strobe Timing

| Strobe      | Condition                                                                                             |
|-------------|-------------------------------------------------------------------------------------------------------|
| `reg_write` | Asserted for 1 clock cycle when `state = DATA_ACK`, `scl_rising = '1'`, and `reg_ptr_set = '1'` (i.e. this is a data byte, not the register pointer byte) |
| `reg_read`  | Asserted for 1 clock cycle on `ADDR_ACK` rising edge (first read) or `DATA_WAIT_ACK` rising edge with master ACK (burst reads). Kept for interface compatibility — has no functional effect since `register_file` uses a combinatorial (asynchronous) read output. |

---

## Timing Diagram (Write Transaction)

```
SCL:   ____/‾‾\__/‾‾\__/‾‾\__  ... __/‾‾\__/‾‾\____
SDA:   ‾‾\          [A6..A0 R/W]  [Reg Addr]  [Data]
           START                                      STOP

state: IDLE → START_DETECTED → ADDR_RECEIVE → ADDR_ACK → DATA_RECEIVE → DATA_ACK → ...
```

---

## Usage / Instantiation

```vhdl
u_i2c_slave : entity work.i2c_slave
    generic map (
        SLAVE_ADDR => "1010000",   -- 0x50
        NUM_REGS   => 16
    )
    port map (
        clk          => sys_clk,
        rst_n        => sys_rst_n,
        scl          => i2c_scl,
        sda_in       => sda_in,
        sda_out      => sda_out,
        sda_oe       => sda_oe,
        reg_addr     => reg_addr,
        reg_data_out => reg_wr_data,
        reg_data_in  => reg_rd_data,
        reg_write    => reg_write,
        reg_read     => reg_read,
        i2c_active   => i2c_active,
        error        => i2c_error
    );
```

---

## Design Notes

- The `scl` input is treated as a pure clock-domain crossing input; the 3-stage synchronizer assumes the system clock is significantly faster than the I2C clock (recommended ≥ 4× the maximum SCL frequency).
- `reg_addr` and `reg_data_out` are continuously driven (not registered output strobes); they are only valid when `reg_write` or `reg_read` is high.
- The first byte received in a write transaction always sets the register pointer (`current_reg_addr`). Actual data bytes begin from the second received byte onward.
- `reg_data_in` is read combinatorially: the register file's output updates immediately when `reg_addr` changes, so no additional pipeline latency needs to be accounted for. The `reg_read` strobe is provided for interface compatibility with future pipelined register-file variants.

---

## Related Modules

| Module          | File                       | Description                                      |
|-----------------|----------------------------|--------------------------------------------------|
| `register_file` | `hdl/register_file.vhd`    | Register storage array connected to this module  |
