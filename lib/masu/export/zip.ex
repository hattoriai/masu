defmodule Masu.Export.Zip do
  @moduledoc false
  # A zip file as a stream, as it is written: each entry deflated as its
  # content comes, its CRC and sizes in a descriptor after it, the central
  # directory at the end. Nothing is held but the deflate state, so an
  # XLSX streams to the browser, or to a file, a block of rows at a time.
  # No ZIP64: an entry and the file stay under 4 GB.

  import Bitwise

  # Bit 3: sizes in the descriptor; bit 11: names in UTF-8.
  @flags 0x0808
  @deflate 8
  @version 20

  @spec stream([{String.t(), Enumerable.t()}]) :: Enumerable.t()
  def stream(entries) do
    {time, date} = dos_time(NaiveDateTime.utc_now())

    entries
    |> Stream.flat_map(fn {name, content} ->
      Stream.concat([[{:start, name}], Stream.map(content, &{:data, &1}), [:stop]])
    end)
    |> Stream.concat([:eof])
    |> Stream.transform(
      fn -> start(time, date) end,
      &event/2,
      fn state -> :zlib.close(state.z) end
    )
  end

  defp start(time, date) do
    z = :zlib.open()
    # Raw deflate: no zlib header, as zip has it.
    :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
    %{z: z, time: time, date: date, offset: 0, entries: [], entry: nil}
  end

  defp event({:start, name}, state) do
    :ok = :zlib.deflateReset(state.z)

    header =
      <<0x04034B50::little-32, @version::little-16, @flags::little-16, @deflate::little-16,
        state.time::little-16, state.date::little-16, 0::32, 0::32, 0::32,
        byte_size(name)::little-16, 0::little-16, name::binary>>

    entry = %{name: name, offset: state.offset, crc: 0, csize: 0, usize: 0}
    emit([header], %{state | entry: entry})
  end

  defp event({:data, data}, %{entry: entry} = state) do
    out = :zlib.deflate(state.z, data)

    entry = %{
      entry
      | crc: :erlang.crc32(entry.crc, data),
        usize: entry.usize + IO.iodata_length(data),
        csize: entry.csize + IO.iodata_length(out)
    }

    emit(out, %{state | entry: entry})
  end

  defp event(:stop, %{entry: entry} = state) do
    out = :zlib.deflate(state.z, [], :finish)
    entry = %{entry | csize: entry.csize + IO.iodata_length(out)}

    descriptor =
      <<0x08074B50::little-32, entry.crc::little-32, entry.csize::little-32,
        entry.usize::little-32>>

    emit([out, descriptor], %{state | entry: nil, entries: [entry | state.entries]})
  end

  defp event(:eof, state) do
    entries = Enum.reverse(state.entries)
    directory = Enum.map(entries, &central(&1, state))
    size = IO.iodata_length(directory)
    count = length(entries)

    eocd =
      <<0x06054B50::little-32, 0::little-16, 0::little-16, count::little-16, count::little-16,
        size::little-32, state.offset::little-32, 0::little-16>>

    {[IO.iodata_to_binary([directory, eocd])], state}
  end

  defp central(entry, state) do
    <<0x02014B50::little-32, @version::little-16, @version::little-16, @flags::little-16,
      @deflate::little-16, state.time::little-16, state.date::little-16, entry.crc::little-32,
      entry.csize::little-32, entry.usize::little-32, byte_size(entry.name)::little-16,
      0::little-16, 0::little-16, 0::little-16, 0::little-16, 0::little-32,
      entry.offset::little-32, entry.name::binary>>
  end

  # What deflate gives back, as one binary, and the offset past it. It
  # holds its output until it has enough: an empty one is not emitted.
  defp emit(iodata, state) do
    case IO.iodata_to_binary(iodata) do
      "" -> {[], state}
      bytes -> {[bytes], %{state | offset: state.offset + byte_size(bytes)}}
    end
  end

  defp dos_time(%NaiveDateTime{} = t) do
    time = t.hour <<< 11 ||| t.minute <<< 5 ||| div(t.second, 2)
    date = (t.year - 1980) <<< 9 ||| t.month <<< 5 ||| t.day
    {time, date}
  end
end
