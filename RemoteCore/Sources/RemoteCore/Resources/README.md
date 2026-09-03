# Client identity — generate your own, do not commit

Android TV's pairing protocol authenticates the remote with a client
certificate. This directory holds that identity, and it is **deliberately
empty in git**: a shared private key would let anyone who cloned this repo
impersonate your remote to any TV that had paired with it.

Generate yours once, before the first build:

```bash
./Scripts/generate-identity.sh
```

That writes `client.p12` and `client.der` here; both are git-ignored. Every
TV remembers this identity at pairing, so re-running the script un-pairs all
of your TVs and they must be paired again.
