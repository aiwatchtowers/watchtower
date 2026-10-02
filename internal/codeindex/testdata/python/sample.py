"""A neutral fixture for the Python query."""

import os

LIMIT = 3
name: str = "box"


# A comment above a function is not its doc.
def top(a, b=1) -> int:
    """Return the larger value. Ties return a."""

    def inner():
        pass

    return max(a, b)


@decorator
def decorated():
    '''Decorated function.'''


class Box(Base):
    """A box that holds things."""

    size = 1

    def __init__(self, size):
        self.size = size

    @property
    def area(self) -> int:
        """The box's
        area, squared."""
        return self.size * self.size

    class Inner:
        def method(self):
            pass


async def fetch(url):
    return url
