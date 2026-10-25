# Spike: Stripe and GoDaddy readers driven from the POS

**Question.** Can the POS drive a Stripe reader (server-driven, no desktop SDK) and a GoDaddy Payments
reader for a sale with tip, a refund, an offline (store-and-forward) sale, and a pre-authorized bar tab
with incremental authorization? What does each cost per transaction at the restaurant's volume?

**Setup.** A Stripe account with Terminal enabled and one reader; a GoDaddy Payments account with its
developer terms and, if allowed, one reader. The backend's payment adapter interface with two
implementations; the Flutter app showing the amounts.

**Pass.** Each flow works on Stripe; each flow either works on GoDaddy or is documented as not offered;
fees per transaction are recorded for the router's cost table.

**Result.** Pending.
