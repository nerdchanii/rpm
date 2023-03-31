# RPM (Rapid node Package Manager)

- [RPM (Rapid node Package Manager)](#rpm-rapid-node-package-manager)
  - [Get started](#get-started)
    - [Installation](#installation)
      - [without clone](#without-clone)
      - [wit git clone](#wit-git-clone)
  - [How to use](#how-to-use)
    - [Avariable Commands](#avariable-commands)
      - [install](#install)
      - [add](#add)
      - [run](#run)
  - [List of available libraries](#list-of-available-libraries)
  - [Contributing](#contributing)

rpm is a fast and easy-to-use package manager for Node.js. It is built with Rust and aims to provide fast performance for managing your Node.js packages.

## Get started

### Installation

#### without clone

> You can follow the script below, or you can use the scripts in [`scripts/withoutclone/installation`](/scripts/withoutclone/installation.sh).
>
1. download rpm.tar.gz

```sh
curl -o rpm.tar.gz -l https://raw.githubusercontent.com/nerdchanii/rpm/main/rpm.tar.gz 
```

2. make /.rpm in User root

```sh
mkdir ~/.rpm
```

3. decompress tar.gz and remove

```sh
tar -zxf rpm.tar.gz -C ~/.rpm && rm rpm.tar.gz
```

4. setup alias

```sh
# with zsh
echo "alias rpm="~/.rpm/rpm"" >> ~/.zshrc

# with bash
echo "alias rpm="~/.rpm/rpm"" >> ~/.bashrc
```

5. apply terminal(or restart)

- ⚠️ if not work relaod terminal or open new Terminal

```sh
# with zsh
source ~/.zshrc

# with bash
source ~/.bashrc
```

#### wit git clone

```bash
# clone 
git clone https://github.coom/nerdchanii/rpm.git && cd rpm 
# if you use zsh
zsh scripts/installation.zsh.sh

# if you use sh 
sh scripts/installation.sh
```

## How to use

### Avariable Commands

#### install

- install packages your needed using package.json

```bash
# ex)
rpm install
```

#### add

```bash
# ex) adding library with latest version
rpm add react
# ex) adding library with specific version
rpm add vite@4.2.0
```

#### run

run command excute your script within package.json

if your package.json

```json
"scripts": {
  "dev": "vite",
  "serve": "node index.js"
  }
```

```sh
# you can excute script
rpm run dev 
rpm run server
```

## List of available libraries

- React
- React-dom
- vite (but, create vite not surpported now.)
- express
- prettier
- vue
- lodash
- svelte

## Contributing

RPM is an open-source project and we welcome contributions from the community. If you'd like to contribute, we encourage you to fork the GitHub repository, make your changes, and submit a pull request. We appreciate all contributions, big or small, and thank you in advance for your help in making RPM better!
