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
  brew install ansible
  ```

- [ ] Clone dotfiles

  ```sh
  mkdir ~/src
  git clone --recursive https://git.kejadlen.dev/alpha/boxen.git ~/src/boxen
  ```

