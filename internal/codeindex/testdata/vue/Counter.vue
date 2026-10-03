<template>
  <div>
    <p>function fakeTemplate() {}</p>
    <button @click="increment">{{ count }}</button>
  </div>
</template>

<script setup lang="ts">
import { ref } from "vue";

/** A counter's public shape. */
interface Counter {
  count: number;
}

const count = ref(0);

/** Adds one to the count. */
function increment(): void {
  count.value++;
}

class Store {
  reset() {}
}
</script>

<style scoped>
p { color: red; }
</style>
