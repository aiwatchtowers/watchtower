<?php

declare(strict_types=1);

namespace Acme\Store;

/** The largest size a store holds. */
const MAX_SIZE = 64;

/** Something that can be stored. */
interface Storable
{
    /** The key this value is stored under. */
    public function key(): string;
}

/** Counts what it touches. */
trait Counts
{
    private int $count = 0;
}

/** Shape of a value. */
enum Shape: string
{
    case Circle = 'circle';
    case Square = 'square';

    public function label(): string
    {
        return ucfirst($this->value);
    }
}

/**
 * A key-value store.
 */
#[Entity(table: 'stores')]
final class Store implements Storable
{
    use Counts;

    /** The default capacity. */
    public const CAPACITY = 8;

    /** The entries, by key. */
    private array $entries = [];

    public function __construct(
        private readonly string $name,
        protected int $limit = 10,
    ) {
    }

    // A plain comment is not a doc.
    public function key(): string
    {
        return $this->name;
    }

    /** Builds an empty store. */
    public static function empty(): self
    {
        return new self('empty');
    }

    abstract protected function hook(): void;
}

// A plain comment is not a doc.
function helper(int $a, int $b): int
{
    return $a + $b;
}

/** Doubles a number. */
function double(int $n): int
{
    $inner = function () {};
    return $n * 2;
}
