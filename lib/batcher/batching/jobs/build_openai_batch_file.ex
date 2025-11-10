defmodule Batcher.Batching.Jobs.BuildOpenaiBatchFile do
  use Oban.Worker, queue: :batcherM
end
