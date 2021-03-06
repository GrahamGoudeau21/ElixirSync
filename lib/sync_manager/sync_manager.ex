defmodule Sync.Sync_Manager do
  def sync(dirs) do
    spawn_managers(dirs)
    wait_forever
  end

  defp spawn_managers(dirs) do
    absolute_dirs = Enum.map dirs, &get_absolute_path/1
    serve_threads = Enum.map absolute_dirs, &(spawn_link(__MODULE__, :setup_serve, [&1]))

    # record the fetch threads with their corresponding directory,
    # so that serve threads avoid serving content to their corresponding fetch threads
    fetch_threads = Enum.map absolute_dirs, &({&1, spawn_link(__MODULE__, :setup_fetch, [&1])})

    broadcast serve_threads, {:fetch_threads, fetch_threads}
  end

  def setup_serve(dir) do
    time_delay = 500

    # get the destinations this thread will serve to (excludes its own directory)
    fetch_threads = receive_fetch_threads dir

    files = get_files dir

    file_digests_map = build_digests_map files

    # do the initial serve, since every file needs updating at the start of execution
    serve_update_files files, fetch_threads
    serve_loop dir, files, file_digests_map, fetch_threads, time_delay
  end

  defp serve_loop(dir, files, file_digests, fetch_threads, time_delay) do
    new_files_list = get_files dir
    new_digests = build_digests_map new_files_list
    updated_files = for file <- new_files_list,
                        Map.get(new_digests, file, nil) != Map.get(file_digests, file, nil),
                        do: file

    deleted_files = files -- new_files_list

    serve_update_files updated_files, fetch_threads
    serve_delete_files deleted_files, fetch_threads

    :timer.sleep(time_delay)
    serve_loop(dir, new_files_list, new_digests, fetch_threads, time_delay)
  end

  defp fetch_loop(dir, time_delay) do
    receive do
      {:update, filename, contents} -> spawn_link(__MODULE__, :handle_fetch_update, [dir, filename, contents])
      {:delete, filename} -> spawn_link(__MODULE__, :handle_fetch_delete, [dir, filename])
    end
    :timer.sleep(time_delay)
    fetch_loop(dir, time_delay)
  end

  def handle_fetch_update(dir, filename, contents) do
    IO.puts "Fetched UPDATE for " <> filename
    File.write! dir <> "/" <> filename, contents
  end

  def handle_fetch_delete(dir, filename) do
    IO.puts "Fetched DELETE for " <> filename

    # wait a short time to see if the file will get automatically cleaned up
    # this can happen with files like vim's *.swp files
    :timer.sleep(500)
    case File.exists?(dir <> "/" <> filename) do
      true -> File.rm! dir <> "/" <> filename
      _ -> :ok
    end
  end

  defp serve_delete_files(files, fetch_threads) do
    map_serve_delete = &(serve_delete_file &1, fetch_threads)
    Enum.map files, map_serve_delete
  end

  defp serve_delete_file(file, fetch_threads) do
    IO.puts "Serving DELETE from " <> file
    broadcast fetch_threads, {:delete, (get_base_name file)}
  end

  defp serve_update_files(files, fetch_threads) do
    map_serve_update = &(serve_update_file &1, fetch_threads)
    Enum.map files, map_serve_update
  end

  defp serve_update_file(file, fetch_threads) do
    IO.puts "Serving UPDATE from " <> file
    {:ok, contents} = File.read file
    broadcast fetch_threads, {:update, (get_base_name file), contents}
  end

  defp get_base_name(file) do
    Path.basename file
  end

  defp receive_fetch_threads(dir) do
    received_fetch_threads = receive do
      {:fetch_threads, fetch_threads} -> fetch_threads
    end
    for {send_dir, pid} <- received_fetch_threads, send_dir != dir, do: pid
  end

  def setup_fetch(dir) do
    time_delay = 500
    fetch_loop(dir, time_delay)
  end

  defp broadcast([], _) do end
  defp broadcast([recipient | recipients], message) do
    send recipient, message
    broadcast(recipients, message)
  end

  defp build_digests_map(files) do
    Enum.map(files, &({&1, get_digest(&1)})) |> Enum.into %{}
  end

  defp get_digest(file) do
    {:ok, contents} = File.read file
    :crypto.hash(:md5, contents)
  end

  defp get_absolute_path(dir) do
    dir |> Path.absname |> Path.expand
  end

  defp get_dir_contents(dir) do
    {:ok, content} = File.ls dir

    # return the contents with their full file paths
    Enum.map content, &(dir <> "/" <> &1)
  end

  defp get_files(dir) do
    dir |> get_dir_contents |> Enum.filter &(not File.dir?(&1))
  end

  defp wait_forever() do
    wait_forever
  end
end
