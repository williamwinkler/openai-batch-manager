defmodule Batcher.Repo.Migrations.MigrateDoneToDelivered do
  @moduledoc """
  Migrates existing batches with :done state to :delivered state.

  This is part of the granular delivery completion states feature:
  - :done is removed
  - :delivered replaces :done for batches where all requests delivered successfully
  - :partially_delivered is for batches where some requests delivered, some failed
  - :delivery_failed is for batches where all requests failed to deliver
  """
  use Ecto.Migration

  def up do
    execute("UPDATE batches SET state = 'delivered' WHERE state = 'done'")
  end

  def down do
    execute("UPDATE batches SET state = 'done' WHERE state = 'delivered'")
  end
end
