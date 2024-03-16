- Create a ruleset in Nixpkgs:
  - Bypass list: Only the nixfmt GitHub app
  - Match all `nixfmt-*` branches
  - Restrict create, update, delete to the bypass list
  - Allow force pushes


Test 1
- Disable webhook
- Leave revoking checked
- Repository permissions:
  - Contents: read/write
- App ID: 857221
  - Added as app_id Actions variable in nixfmt
- Generate secret key (gets downloaded as a file)
  - Store the secret as app_private_key Actions secret in nixfmt
- Install on the organisation
  - Only give it access to nixpkgs



Problem: Can also push to master and merge PRs
Solution: An extra Nixpkgs ruleset:
- Bypass list: Everybody with write access
- Match all branches except `nixfmt-*`
- Only allow create, update and delete
- Deselect all others
