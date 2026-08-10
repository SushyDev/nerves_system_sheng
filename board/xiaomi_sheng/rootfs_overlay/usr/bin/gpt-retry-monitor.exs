#!/usr/bin/env elixir
#
# GPT Retry-Count Monitor for Phase 0 empirical testing
#
# Usage: elixir gpt-retry-monitor.exs [read|watch]
#   read  - show current retry-count and success-bit for both slots
#   watch - continuously read after each reboot (save this file, SSH back, run)
#
# This determines whether ABL decrements the retry-count nibble (bits 3-5,
# mask 0x38) on EVERY boot or only on FAILED boots.
#
# Bits in the GPT attribute byte (offset 54 per entry):
#   0-1: priority (2-bit)
#   2:   ACTIVE (1-bit) -- bit 0x04
#   3-5: retry count (3-bit) -- bits 0x38 (mask), values 0-7
#   6:   SUCCESSFUL (1-bit) -- bit 0x40
#   7:   UNBOOTABLE (1-bit) -- bit 0x80

defmodule GPTRetryMonitor do
  @boot_a_attr_offset 9910   # 8192 + 13*128 + 54
  @boot_b_attr_offset 13750  # 8192 + 43*128 + 54

  def read_attr_byte(disk, offset) do
    case File.open(disk, [:read, :binary]) do
      {:ok, fd} ->
        case :file.pread(fd, offset, 1) do
          {:ok, <<byte>>} ->
            :file.close(fd)
            {:ok, byte}
          error ->
            :file.close(fd)
            error
        end
      error ->
        error
    end
  end

  def decode_attr(attr_byte) do
    active = (attr_byte &&& 0x04) != 0
    retry_count = (attr_byte &&& 0x38) >> 3
    success = (attr_byte &&& 0x40) != 0
    unbootable = (attr_byte &&& 0x80) != 0

    %{
      raw_byte: attr_byte,
      hex: "0x#{Integer.to_string(attr_byte, 16) |> String.pad_leading(2, "0")}",
      active: active,
      retry_count: retry_count,
      success: success,
      unbootable: unbootable
    }
  end

  def get_active_slot(disk) do
    with {:ok, a_byte} <- read_attr_byte(disk, @boot_a_attr_offset),
         {:ok, b_byte} <- read_attr_byte(disk, @boot_b_attr_offset) do
      a_active = (a_byte &&& 0x04) != 0
      b_active = (b_byte &&& 0x04) != 0

      case {a_active, b_active} do
        {true, false} -> {:ok, :a}
        {false, true} -> {:ok, :b}
        _ -> {:error, "Ambiguous or no active slot"}
      end
    end
  end

  def show_slots(disk) do
    IO.puts("\n=== GPT Attribute Bytes (#{disk}) ===")
    IO.puts("Timestamp: #{DateTime.utc_now() |> DateTime.to_string()}\n")

    case read_attr_byte(disk, @boot_a_attr_offset) do
      {:ok, a_byte} ->
        a_info = decode_attr(a_byte)
        IO.puts("boot_a (entry 13, offset #{@boot_a_attr_offset}):")
        IO.puts("  Raw: #{a_info.hex}")
        IO.puts("  Active: #{a_info.active}")
        IO.puts("  Retry count: #{a_info.retry_count}/7")
        IO.puts("  Success: #{a_info.success}")
        IO.puts("  Unbootable: #{a_info.unbootable}")
        IO.puts("")

      error ->
        IO.puts("Error reading boot_a: #{inspect(error)}")
    end

    case read_attr_byte(disk, @boot_b_attr_offset) do
      {:ok, b_byte} ->
        b_info = decode_attr(b_byte)
        IO.puts("boot_b (entry 43, offset #{@boot_b_attr_offset}):")
        IO.puts("  Raw: #{b_info.hex}")
        IO.puts("  Active: #{b_info.active}")
        IO.puts("  Retry count: #{b_info.retry_count}/7")
        IO.puts("  Success: #{b_info.success}")
        IO.puts("  Unbootable: #{b_info.unbootable}")

      error ->
        IO.puts("Error reading boot_b: #{inspect(error)}")
    end

    case get_active_slot(disk) do
      {:ok, slot} -> IO.puts("\nCurrent active slot: #{slot}")
      {:error, msg} -> IO.puts("\nError: #{msg}")
    end
  end

  def run(args) do
    disk = "/dev/block/by-name/userdata" || "/dev/mmcblk0"
    # Try to resolve disk if by-name doesn't exist
    disk =
      if not File.exists?(disk) do
        "/dev/mmcblk0"
      else
        disk
      end

    case args do
      ["read"] ->
        show_slots(disk)

      ["watch"] ->
        IO.puts("Watching retry-count across reboots...")
        IO.puts("After each reboot, this will print the current state.")
        IO.puts("Press Ctrl+C to stop.\n")

        loop = fn loop_fn ->
          show_slots(disk)
          IO.puts("\n[Waiting for reboot or manual retry; press Enter to read again, Ctrl+C to exit]")
          IO.read(:stdio, :line)
          loop_fn.(loop_fn)
        end

        try do
          loop.(loop)
        catch
          :exit, _ -> IO.puts("\nExited.")
        end

      _ ->
        IO.puts("Usage: elixir gpt-retry-monitor.exs [read|watch]")
        IO.puts("")
        IO.puts("  read  - show current retry-count and success-bit for boot_a/boot_b")
        IO.puts("  watch - interactive: press Enter to re-read after each reboot")
        System.halt(1)
    end
  end
end

GPTRetryMonitor.run(System.argv())
