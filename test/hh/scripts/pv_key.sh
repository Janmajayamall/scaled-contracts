keys=$(openssl ecparam -name secp256k1 -genkey -noout | openssl ec -text -noout 2> /dev/null)

# extract private key in hex format, removing newlines, leading zeroes and semicolon
priv=$(printf "%s\n" $keys | grep priv -A 3 | tail -n +2 | tr -d '\n[:space:]:' | sed 's/^00//') 

# make sure priv has correct length
# if [ ${#priv} -ne 64 ]; then
#     echo "length error"
#     exit
# fi

priv="0x${priv}"
echo $priv
