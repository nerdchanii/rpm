curl -o rpm.tar.gz -l https://raw.githubusercontent.com/nerdchanii/rpm/main/rpm.tar.gz 
# make /.rpm in User root
mkdir ~/.rpm
# decompress tar.gz and remove
tar -zxf rpm.tar.gz -C ~/.rpm && rm rpm.tar.gz
echo "choose your shell to install rpm using number"
select sehll in "zsh" "bash"
do
    case $sehll in
        "zsh")
                if echo "alias rpm='~/.rpm/rpm'" >> ~/.zshrc  ;
                then
                    source ~/.zshrc >/dev/null 2>&1;
                    echo "rpm has been installed successfully";
                    break
                fi
            ;;
        "bash")
            echo "alias rpm="~/.rpm/rpm"" >> ~/.bashrc;
            cd .;
            break
            ;;
        *)
            echo "Please select zsh or bash"
            ;;
    esac
done


