- [ ] Install homebrew

  ```sh
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ```

- [ ] Load homebriew

  ```sh
  eval "$(/opt/homebrew/bin/brew shellenv)"
  ```

- [ ] Install bootstrapping tooling

  ```sh
  brew install ansible git jujutsu
  ```

- [ ] Clone dotfiles

  ```sh
  jj git clone --recursive https://github.com/kejadlen/dotfiles.git ~/.dotfiles
  ```

