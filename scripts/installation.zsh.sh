# zsh scripts
mkdir ~/.rpm &&
tar -zxf rpm.tar.gz -C ~/.rpm &&
echo "alias rpm="~/.rpm/rpm"" >> ~/.zshrc &&
echo "rpm has been installed successfully" &&
source ~/.zshrc &&
cd .
