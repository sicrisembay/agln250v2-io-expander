# Register File

**File:** `hdl/register_file.vhd`  
**Author:** FPGA Designer  
**Created:** July 27, 2025  
**Project:** I2C Slave Implementation (AGLN250V2 IO Expander)

---

## Overview

`register_file` is a synchronous register array designed to be paired with the `i2c_slave` controller. It provides 16 byte-wide registers accessible over both the I2C register bus and a dedicated application interface. Specific registers are assigned fixed roles (device ID, control, status, version, and four general-purpose data registers), while the remaining addresses are reserved.

---

## Generics

| Name       | Type      | Default | Description              |
|------------|-----------|---------|--------------------------|
| `NUM_REGS` | `integer` | `16`    | Total number of registers |

---

## Port Description

### System Signals

| Port    | Direction | Width | Description                  |
|---------|-----------|-------|------------------------------|
| `clk`   | in        | 1     | System clock                 |
| `rst_n` | in        | 1     | Active-low synchronous reset |

### Register Bus Interface

These ports connect directly to the `i2c_slave` module.

| Port           | Direction | Width | Description                                   |
|----------------|-----------|-------|-----------------------------------------------|
| `reg_addr`     | in        | 8     | Register address to access                    |
| `reg_data_in`  | in        | 8     | Write data from I2C slave                     |
| `reg_data_out` | out       | 8     | Read data returned to I2C slave               |
| `reg_write`    | in        | 1     | Write strobe — latches `reg_data_in` on rising edge |
| `reg_read`     | in        | 1     | Read strobe — updates `reg_data_out` on rising edge |

### Application Interface

These ports expose selected registers to application logic in the surrounding design.

| Port          | Direction | Width | Register Address | Description                            |
|---------------|-----------|-------|------------------|----------------------------------------|
| `control_reg` | out       | 8     | `0x01`           | Control register value                 |
| `status_reg`  | in        | 8     | `0x02`           | Status value written into the register |
| `data_reg0`   | out       | 8     | `0x04`           | Data register 0                        |
| `data_reg1`   | out       | 8     | `0x05`           | Data register 1                        |
| `data_reg2`   | out       | 8     | `0x06`           | Data register 2                        |
| `data_reg3`   | out       | 8     | `0x07`           | Data register 3                        |

---

## Register Map

| Address | Name          | Access      | Reset Value | Description                                              |
|---------|---------------|-------------|-------------|----------------------------------------------------------|
| `0x00`  | `ID_REG`      | Read-only   | `0xA5`      | Device identification byte. Hardcoded to `0xA5`.         |
| `0x01`  | `CONTROL_REG` | Read/Write  | `0x00`      | Control register. Written by I2C master; read by application logic via `control_reg`. |
| `0x02`  | `STATUS_REG`  | Read-only   | `0x00`      | Status register. Updated every clock cycle from the `status_reg` input port. Write attempts are ignored. |
| `0x03`  | `VERSION_REG` | Read-only   | `0x01`      | Firmware version. Hardcoded to `0x01`.                   |
| `0x04`  | `DATA_REG0`   | Read/Write  | `0x00`      | General-purpose data register 0.                         |
| `0x05`  | `DATA_REG1`   | Read/Write  | `0x00`      | General-purpose data register 1.                         |
| `0x06`  | `DATA_REG2`   | Read/Write  | `0x00`      | General-purpose data register 2.                         |
| `0x07`  | `DATA_REG3`   | Read/Write  | `0x00`      | General-purpose data register 3.                         |
| `0x08`–`0x0F` | —       | Reserved    | `0x00`      | No function assigned. Writes are ignored; reads return `0x00`. |

> **Note:** Addresses `0x08` through `0x0F` exist in the register array but have no special write logic.  
> Addresses ≥ `NUM_REGS` (≥ 16 / `0x10`) are clamped to index 0 on write and return `0x00` on read.

---

## Internal Architecture

### Register Array

The storage is a single array of `NUM_REGS` × 8-bit registers:

```vhdl
type reg_array_type is array (0 to NUM_REGS-1) of std_logic_vector(7 downto 0);
signal registers : reg_array_type;
```

### Address Decoding

The 8-bit `reg_addr` input is converted to an integer. If the address is out of range (`>= NUM_REGS`), it is clamped to `0` to prevent array index violations:

```vhdl
addr_int <= to_integer(unsigned(reg_addr)) when to_integer(unsigned(reg_addr)) < NUM_REGS else 0;
```

### Write Process

On every rising clock edge:
1. `registers(STATUS_REG_ADDR)` is unconditionally updated from the `status_reg` input (live hardware status mirror).
2. If `reg_write = '1'`, the addressed register is updated — only for writable addresses (`0x01`, `0x04`–`0x07`). Read-only addresses (`0x00`, `0x02`, `0x03`) are ignored.

### Read Process

On every rising clock edge when `reg_read = '1'`:
- `reg_data_out` is loaded from `registers(addr_int)`.
- If `addr_int >= NUM_REGS`, `reg_data_out` is set to `0x00`.

Read data is registered (one-cycle latency after the `reg_read` strobe).

### Reset Behaviour

On de-assertion of `rst_n` (synchronous):
- All registers are cleared to `0x00`.
- `registers(0x00)` is initialised to the device ID constant (`0xA5`).
- `registers(0x03)` is initialised to the version constant (`0x01`).

---

## Functional Description

### Status Register Live Update

The `STATUS_REG` at address `0x02` is not writable by the I2C master. Instead, it reflects the current value of the `status_reg` input port, which is updated on every clock cycle:

```vhdl
registers(STATUS_REG_ADDR) <= status_reg;   -- runs every rising edge
```

This guarantees that an I2C read of address `0x02` always returns the most recent hardware status.

### Read-Only Protection

The write process uses an explicit `case` statement. Addresses not listed (`0x00`, `0x02`, `0x03`, and all reserved addresses) match the `when others => null` branch, effectively discarding any write.

---

## Usage / Instantiation

```vhdl
u_register_file : entity work.register_file
    generic map (
        NUM_REGS => 16
    )
    port map (
        clk          => sys_clk,
        rst_n        => sys_rst_n,
        -- Register bus (from i2c_slave)
        reg_addr     => reg_addr,
        reg_data_in  => reg_wr_data,
        reg_data_out => reg_rd_data,
        reg_write    => reg_write,
        reg_read     => reg_read,
        -- Application interface
        control_reg  => ctrl_bits,
        status_reg   => status_bits,
        data_reg0    => data0,
        data_reg1    => data1,
        data_reg2    => data2,
        data_reg3    => data3
    );
```

---

## Top-Level Connection

The `i2c_slave` and `register_file` modules are intended to be wired together as follows:

```
                 ┌───────────────┐         ┌──────────────────┐
  I2C Master ───►│               │reg_addr►│                  │
                 │  i2c_slave    │reg_data►│  register_file   │◄─── status_reg (HW)
                 │               │◄reg_data│                  │
                 │  (SLAVE_ADDR) │reg_write│                  │───► control_reg (App)
                 │               │reg_read►│                  │───► data_reg0-3 (App)
                 └───────────────┘         └──────────────────┘
```

---

## Related Modules

| Module      | File                  | Description                                              |
|-------------|-----------------------|----------------------------------------------------------|
| `i2c_slave` | `hdl/i2c_slave.vhd`   | I2C slave controller that drives the register bus inputs |
