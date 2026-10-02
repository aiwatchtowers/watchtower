// A tiny TypeScript fixture for the full grammar set.

/** The largest size a store holds. */
export const MAX_SIZE: number = 64;

/** Something that can be stored. */
export interface Storable {
  /** The key this value is stored under. */
  key(): string;
  readonly size: number;
}

/** An id, as a string. */
export type Id = string;

/** Shape of a value. */
export enum Shape {
  Circle,
  Square,
}

/** A key-value store. */
export class Store<T> implements Storable {
  private entries: Map<string, T> = new Map();

  constructor(private readonly name: string) {}

  /** Adds a value under a key. */
  add(key: string, value: T): void {
    this.entries.set(key, value);
  }

  key(): string {
    return this.name;
  }

  get size(): number {
    return this.entries.size;
  }
}

/** The base of every shape. */
export abstract class Base {
  abstract area(): number;
}

/** Inner helpers. */
export namespace Helpers {
  export function assist(): void {}
}

declare function external(input: string): number;

// A plain comment is not a doc.
function helper(a: number, b: number): number {
  const local = 1;
  return a + b + local;
}

/** Doubles a number. */
export const double = (n: number): number => n * 2;
