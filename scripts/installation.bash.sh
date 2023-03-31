# bash scripts
mkdir ~/.rpm ;
tar -xf rpm.tar.gz -C ~/.rpm ;
echo "alias rpm="~/.rpm/rpm"" >> ~/.bashrc ;
echo "rpm has been installed successfully" ;
