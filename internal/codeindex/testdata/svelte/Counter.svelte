<script context="module" lang="ts">
  /** Options every counter takes. */
  export interface Options {
    size: number;
  }
</script>

<script lang="ts">
  export let start = 0;

  /** Moves the count by one step. */
  function step(by: number): number {
    return start + by;
  }

  class Tally {
    total() { return 0; }
  }
</script>

<h1>function fakeMarkup() {}</h1>

<style>
  h1 { color: blue; }
</style>
