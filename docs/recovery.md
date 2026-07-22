# Recovery (design — implemented in M3)

There is no server and no Keychain, so a forgotten master password is unrecoverable **unless** the user opts in at vault creation:

- **Recovery key:** a high-entropy random key → recovery KEK → second AEAD wrap of the VMK stored in the header (object type 6 in the AAD table). Shown exactly once with a printable sheet; confirmation of selected word groups is mandatory; Zyquo never stores it in plaintext. Declining is allowed and respected.
- **Optional offline recovery package**, separately encrypted.

Plain statements the UI must make: recovery key + vault file = full access — store it like cash; losing both password and key = permanent loss. No security questions. No email recovery.
