// A tiny C# fixture for the full grammar set.
using System.Collections.Generic;

namespace Acme.Store;

/// <summary>Something that can be stored.</summary>
public interface IStorable
{
    /// <summary>The key this value is stored under.</summary>
    string Key();

    int Size { get; }
}

/// <summary>
/// A key-value store.
/// </summary>
[Serializable]
public sealed class Store<T> : IStorable
{
    /// <summary>The largest size a store holds.</summary>
    public const int MaxSize = 64;

    private readonly Dictionary<string, T> entries = new();

    /// <summary>The number of entries.</summary>
    public int Size => entries.Count;

    public event EventHandler Changed;

    public Store()
    {
    }

    // A plain comment is not a doc.
    public string Key()
    {
        int local = 1;
        return "store" + local;
    }

    /// <summary>Adds a value under a key.</summary>
    public void Add(string key, T value) => entries[key] = value;
}

/// <summary>Shape of a value.</summary>
public enum Shape
{
    Circle,
    Square,
}

/// <summary>A point in the plane.</summary>
public struct Point
{
    public int X;
}

/// <summary>A labelled value.</summary>
public record Label(string Text);

public delegate void Handler(string message);
