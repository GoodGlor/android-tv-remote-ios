# IME wire captures — MiTV-MOSR1 (Android 11), 2026-08-20

Raw messages captured from the real TV during the IME spike (varint length
frame already stripped; hex bytes are the RemoteMessage payload). These are
the ground-truth fixtures for RemoteCore's Wire/ImeMessages tests. Decode any
line with: `./Scripts/probe.sh decode` (feed it `raw: <hex>` lines on stdin).

## TV → phone

### Focus + initial status (field 20, browser field "Пошук", empty, counter 7)
raw: a2 01 56 0a 3c 08 01 10 11 18 86 80 80 60 38 00 40 00 52 0a d0 9f d0 be d1 88 d1 83 d0 ba 62 16 63 6f 6d 2e 69 6e 74 65 72 6e 65 74 2e 74 76 62 72 6f 77 73 65 72 68 ff ff ff ff ff ff ff ff ff 01 12 16 08 07 12 00 18 00 20 00 28 01 32 0a d0 9f d0 be d1 88 d1 83 d0 ba

### Typing й, йц, йцу in the browser (field 22, counters 16-18)
raw: b2 01 1a 12 18 08 10 12 02 d0 b9 18 01 20 01 28 01 32 0a d0 9f d0 be d1 88 d1 83 d0 ba
raw: b2 01 1c 12 1a 08 11 12 04 d0 b9 d1 86 18 02 20 02 28 01 32 0a d0 9f d0 be d1 88 d1 83 d0 ba
raw: b2 01 1e 12 1c 08 12 12 06 d0 b9 d1 86 d1 83 18 03 20 03 28 01 32 0a d0 9f d0 be d1 88 d1 83 d0 ba

### IME active / inactive flips (field 21)
raw: aa 01 04 08 00 10 00
raw: aa 01 04 08 00 10 01
raw: aa 01 04 08 01 10 00
raw: aa 01 04 08 01 10 01

### App switch, no text field (field 20, YouTube — app info only)
raw: a2 01 21 0a 1f 62 1d 63 6f 6d 2e 67 6f 6f 67 6c 65 2e 61 6e 64 72 6f 69 64 2e 79 6f 75 74 75 62 65 2e 74 76

### Search suggestion push (field 29, katniss)
raw: ea 01 35 08 0d 12 31 08 00 10 00 1a 2b d0 b9 d0 be d0 b3 d0 b0 20 d1 83 d1 80 d0 be d0 ba d0 b8 20 d0 b8 20 d1 82 d1 80 d0 b5 d0 bd d0 b8 d1 80 d0 be d0 b2 d0 ba d0 b8

### Rich EditorInfo status (field 20, katniss global search)
raw: a2 01 b0 02 0a db 01 08 14 10 01 18 83 80 80 40 22 64 63 6f 6d 2e 67 6f 6f 67 6c 65 2e 61 6e 64 72 6f 69 64 2e 69 6e 70 75 74 6d 65 74 68 6f 64 2e 6c 61 74 69 6e 2e 6e 6f 44 65 63 6f 64 69 6e 67 2c 63 6f 6d 2e 67 6f 6f 67 6c 65 2e 61 6e 64 72 6f 69 64 2e 69 6e 70 75 74 6d 65 74 68 6f 64 2e 6c 61 74 69 6e 2e 6e 6f 4d 69 63 72 6f 70 68 6f 6e 65 4b 65 79 38 00 40 00 52 44 d0 a8 d1 83 d0 ba d0 b0 d0 b9 d1 82 d0 b5 20 d1 84 d1 96 d0 bb d1 8c d0 bc d0 b8 2c 20 d1 81 d0 b5 d1 80 d1 96 d0 b0 d0 bb d0 b8 2c 20 d0 b4 d0 be d0 b4 d0 b0 d1 82 d0 ba d0 b8 20 d1 82 d0 be d1 89 d0 be 62 1a 63 6f 6d 2e 67 6f 6f 67 6c 65 2e 61 6e 64 72 6f 69 64 2e 6b 61 74 6e 69 73 73 68 81 85 ac f8 07 12 50 08 32 12 00 18 00 20 00 28 01 32 44 d0 a8 d1 83 d0 ba d0 b0 d0 b9 d1 82 d0 b5 20 d1 84 d1 96 d0 bb d1 8c d0 bc d0 b8 2c 20 d1 81 d0 b5 d1 80 d1 96 d0 b0 d0 bb d0 b8 2c 20 d0 b4 d0 be d0 b4 d0 b0 d1 82 d0 ba d0 b8 20 d1 82 d0 be d1 89 d0 be

## Phone → TV (all ACCEPTED by the TV; from the settext runs)

### ime_show_request echoing status counter 85, empty value
raw: b2 01 0c 12 0a 08 55 12 00 18 00 20 00 28 01
(TV replied with field 21 {0,0}; only answered while its keyboard was open)

### Clear: batch edit delete-2 (net-negative → tail delete; value ignored)
raw: aa 01 10 08 00 10 00 1a 0a 08 01 12 06 08 00 10 02 1a 00

### Append "чудово" (net-positive → append at cursor)
raw: aa 01 1c 08 00 10 00 1a 16 08 01 12 12 08 00 10 00 1a 0c d1 87 d1 83 d0 b4 d0 be d0 b2 d0 be

### The accepted-edit echo (field 22, counter 112, value "чудово")
The TV confirms every accepted edit by streaming the new absolute status.

## Rejected/ignored shapes (regression guard)
A bare batch edit with NO preceding show request, or with stale counters, is
silently ignored (no drop). A show request echoing the field's VALUE (not
empty) is ignored. See phase2-notes.md "IME write direction" for the model.
