- [ ] Set computer name (System Settings -> General -> Sharing)

- [ ] Install homebrew

  ```sh
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ```

- [ ] Load homebrew

  ```sh
  eval "$(/opt/homebrew/bin/brew shellenv)"
  ```

- [ ] Install bootstrapping tooling

  ```sh
  brew install 1password ansible
  ```

Set up 1Password, so that the SSH agent is already set up once ~/.gitconfig is
in place.

- [ ] Set up 1Password
  - [ ] Set up the SSH agent
  - [ ] Temporarily enable the 1Password identity agent in ~/.ssh/config

- [ ] Grant Terminal.app full disk access (System Settings > Privacy & Security > Full Disk Access)

- [ ] Clone setup repo

  ```sh
  mkdir ~/src
  git clone --recursive https://git.kejadlen.dev/alpha/boxen.git ~/src/boxen
  ```

- [ ] Run Ansible

  ```sh
  ansible-playbook local/main.yml
  ```

- [ ] Install Neovim

  ```sh
  brew install tree-sitter --HEAD # sometimes needed
  brew install neovim --HEAD
  ```

- [ ] Grant Ghostty full disk access (System Settings > Privacy & Security > Full Disk Access)

# macOS things

## Settings

- [ ] Control Center
  - [ ] Automatically hide and show the menu bar -> Always
- [ ] Desktop & Dock
- [ ] Displays
  - [ ] More Space
- [ ] Keyboard
  - [ ] Remap ⇪ to ⌃ (Keyboard Shortcuts -> Modifier Keys)

## Apps

- [ ] Aerospace
- [ ] Alfred
- [ ] Dictionary
  - [ ] Enable Webster's 1913 dictionary
  - [ ] Set Webster's 1913 as the first dictionary
- [ ] Safari
  - [ ] Tab layout: Compact (Settings -> Tabs)
  - [ ] Show features for web developers (Settings -> Advanced)
- [ ] OrbStack
- [ ] Tailscale
