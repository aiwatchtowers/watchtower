// A tiny C++ fixture for the full grammar set.

#include <string>

/// The largest size a store holds.
constexpr int kMaxSize = 64;

namespace acme {

/// Something that can be stored.
class Storable {
public:
    /// The key this value is stored under.
    virtual std::string key() const = 0;
    virtual ~Storable() = default;
};

/**
 * A key-value store.
 */
template <typename T>
class Store : public Storable {
public:
    /// Builds an empty store.
    Store();

    std::string key() const override { return name_; }

    /// Adds a value under a key.
    void add(const std::string& key, T value);

private:
    std::string name_;
    int count_ = 0;
};

/// Shape of a value.
enum class Shape { Circle, Square };

struct Point {
    int x;
    int y;
};

using Id = unsigned long;

}  // namespace acme

// A plain comment is not a doc.
template <typename T>
void acme::Store<T>::add(const std::string& key, T value) {
    auto local = [](int n) { return n; };
    count_ += local(1);
}

/// Doubles a number.
int twice(int n) {
    return n * 2;
}
