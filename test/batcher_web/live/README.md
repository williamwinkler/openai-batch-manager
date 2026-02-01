# LiveView Pagination Tests

This directory contains comprehensive tests for pagination functionality in LiveView components that use Ash resources.

## Test Structure

The tests follow Phoenix LiveView testing best practices and Ash Phoenix integration patterns:

- **LiveViewCase**: Custom test case module that sets up proper LiveView testing environment
- **BatchIndexLiveTest**: Tests pagination for the batches index page
- **RequestIndexLiveTest**: Tests pagination for the requests index page

## Testing Patterns

### Based on Context7 Documentation

Our tests follow patterns recommended in the Ash Phoenix and Phoenix LiveView documentation:

1. **Using `Phoenix.LiveViewTest`**: All tests use `live/2` to mount LiveViews and `render_click/2` to simulate interactions
2. **Element-based assertions**: Tests use `has_element?/2`, `element/2`, and `render/1` to check UI state
3. **AshPhoenix.LiveView utilities**: The implementation uses:
   - `AshPhoenix.LiveView.page_from_params/3` (deprecated, but still functional)
   - `AshPhoenix.LiveView.page_link_params/2` for generating pagination URLs
   - `AshPhoenix.LiveView.next_page?/1` and `prev_page?/1` for button state

### Test Coverage

Both test files cover:

#### Pagination Tests

1. **Pagination Controls Display**: Verifies pagination buttons are rendered
2. **Button States**: Tests disabled states on first/last pages
3. **Navigation**: Verifies clicking Next/Previous navigates correctly
4. **Parameter Preservation**: Ensures query text and sort parameters persist across pages
5. **Edge Cases**: Tests empty results scenario

#### Sorting Tests

1. **Sort Dropdown Display**: Verifies sort dropdown is present and functional
2. **Default Sort**: Tests that default sort (newest first) is applied
3. **Sort Option Changes**: Tests that changing sort options updates URL and results
4. **All Sort Options**: Tests each available sort option (ascending/descending for each field)
5. **Parameter Preservation**: Ensures query and pagination parameters are preserved when sorting
6. **Invalid Sort Handling**: Tests that invalid sort options default to newest first
7. **Sort Options Availability**: Verifies all expected sort options are present in dropdown

### Key Testing Functions

```elixir
# Mount a LiveView
{:ok, view, _html} = live(conn, ~p"/")

# Check element presence
assert has_element?(view, "a", "Previous")

# Get element and render it
element(view, "a", "Next") |> render()

# Simulate click
view |> element("a", "Next") |> render_click()

# Verify navigation
assert_patch(view, ~p"/?offset=15&limit=15")

# Test form changes (for sorting)
view
|> element("form[phx-change='change-sort']")
|> render_change(%{"sort_by" => "model"})

# Verify sort was applied
assert_patch(view, ~p"/?sort_by=model")
```

## Implementation Notes

### Pagination Implementation

The LiveView uses offset-based pagination with Ash:

```elixir
page = Ash.read!(query,
  page: AshPhoenix.LiveView.page_from_params(params, @per_page) ++ [count: true]
)
```

### Pagination Links

Pagination links are generated using:

```elixir
defp query_string(page, query_text, sort_by, which) do
  case AshPhoenix.LiveView.page_link_params(page, which) do
    :invalid -> []
    list -> list
  end
  |> Keyword.put(:q, query_text)
  |> Keyword.put(:sort_by, sort_by)
  |> remove_empty()
end
```

### Button Disabled States

Buttons are disabled based on page state:

```elixir
class={["join-item btn btn-sm", !AshPhoenix.LiveView.prev_page?(@page) && "btn-disabled"]}
```

## Future Improvements

Based on Context7 documentation:

1. **Migrate to `params_to_page_opts/2`**: The `page_from_params/3` function is deprecated. Consider migrating to:
   ```elixir
   page: AshPhoenix.LiveView.params_to_page_opts(params, limit: @per_page, count: true)
   ```

2. **Consider `assign_page_and_stream_result/3`**: For cleaner code, could use:
   ```elixir
   socket
   |> AshPhoenix.LiveView.assign_page_and_stream_result(page, 
     results_key: :batches, 
     page_key: :page
   )
   ```

3. **Test with `keep_live/4`**: If implementing live updates, test the `keep_live` pattern for real-time pagination updates.

## Running Tests

```bash
# Run all LiveView tests
mix test test/batcher_web/live/

# Run specific test file
mix test test/batcher_web/live/batch_index_live_test.exs

# Run with verbose output
mix test test/batcher_web/live/ --trace
```

## References

- [Phoenix LiveView Testing](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveViewTest.html)
- [Ash Phoenix LiveView Utilities](https://hexdocs.pm/ash_phoenix/AshPhoenix.LiveView.html)
- [Ash Phoenix Pagination](https://hexdocs.pm/ash_phoenix/AshPhoenix.LiveView.html#page_link_params/2)
