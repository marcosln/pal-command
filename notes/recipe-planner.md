# Recipe-aware order planner

## Decision

Recipe costs must come from Palworld's runtime recipe database, not a hand-kept
wiki table. The wiki is useful for localized names and spot checks only. The app
must calculate against the selected base, because `inventory.json` already keeps
base containers separate while `totals` combines the whole server and guild
chest.

## Data contract

`data/recipes.json` is emitted by the mod and included in `/api/snapshot`:

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-09-15T00:00:00Z",
  "recipes": {
    "ExampleRecipeId": {
      "output": { "item": "ExampleItemId", "quantity": 1 },
      "ingredients": [
        { "item": "MaterialA", "quantity": 2 },
        { "item": "MaterialB", "quantity": 1 }
      ]
    }
  }
}
```

Recipe id and output item id are deliberately separate: Palworld has several
recipe ids that produce the same displayed item. Every alternative stays as its
own definition.

## Calculation

For one recipe, available batches are the minimum of
`floor(free ingredient / quantity per batch)`. Craftable output is batches times
the recipe output quantity. `free` is selected-base storage minus ingredients
reserved by queued and in-progress PalCommand orders. Guild-chest inventory is
not attributed to a base until live testing proves a selected machine can consume
it.

The detail panel shows, for every ingredient: required for the requested output,
available in the selected base, reserved, and missing. A missing ingredient is a
link only if at least one station exposes a recipe whose output item matches it.
Following the link preserves the base and pre-fills the missing quantity.

## Quantity policy

Default submit is capped to the currently craftable quantity when recipe data is
complete and the snapshot is fresh. If zero can be made, submit is disabled. A
separate, explicit `Poner todo en cola` action may send the original amount so it
waits for future materials. Missing or partial recipe data never silently caps an
order; the UI says the cost is unavailable instead.

## Correctness cases

- Round requested output up to whole recipe batches, then show the actual output.
- Do not merge alternative recipes merely because their localized names match.
- Reserve shared ingredients once across queued orders in FIFO order.
- Detect recursive cycles and cap traversal depth when opening child recipes.
- Label inventory as stale while a force refresh is running.
- Energy, fuel, work suitability, and Pal availability affect readiness, not the
  material maximum, unless the recipe definition explicitly consumes fuel.

## Runtime extraction

Static analysis already identified the server's recipe lookup used by
`ChangeRecipe_ServerInternal`: the returned recipe definition contains its
ingredient array around the observed `+0x70` region. The next safe step is a
read-only UE4SS reflection probe of the recipe manager/row struct on the current
server build. Only after field names and types are confirmed should normal scans
emit the catalog. Avoid hard-coded memory offsets in Lua; they are build-specific
and could crash after a Palworld update.
