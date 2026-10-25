# Delivery line fixtures

Each `*.json` pins one line shared with the Swift twin (`ReviewDeliveryLine`).

- `round_id`: the round id.
- `comments`: comment count (sent lines only).
- `kind`: optional; `"approved"` pins `ApprovedLine`; absent means `DeliveryLine`.
- `line`: the exact expected text.
