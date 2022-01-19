# a file to write captured warnings to
# it cannot be a variable, because the warnings function may be used in a pipeline, which causes a subshell, which can't modify parent scope variables
_captured_warnings_file=$(mktemp -t heroku-buildpack-php-captured-warnings-XXXX)

error() {
	# send all of our output to stderr
	exec 1>&2
	# if arguments are given, redirect them to stdin
	# this allows the funtion to be invoked with a string argument, or with stdin, e.g. via <<-EOF
	(( $# )) && exec <<< "$@"
	echo -e "\033[1;31m" # bold; red
	echo -n " !     ERROR: "
	# this will be fed from stdin
	indent no_first_line_indent " !     "
	if [[ -s "$_captured_warnings_file" ]]; then
		echo "" | indent "" " !     "
		echo -e "\033[1;33mREMINDER:\033[1;31m the following \033[1;33mwarnings\033[1;31m were emitted during the build;" | indent "" " !     "
		echo "check the details above, as they may be related to this error:" | indent "" " !     "
		cat "$_captured_warnings_file" | indent "" "$(echo -e " !     \033[1;33m-\033[1;31m ")"
	fi
	echo -e "\033[0m" # reset style
	exit 1
}

warning() {
	# send all of our output to stderr
	exec 1>&2
	# if arguments are given, redirect them to stdin
	# this allows the funtion to be invoked with a string argument, or with stdin, e.g. via <<-EOF
	(( $# )) && exec <<< "$@"
	echo -e "\033[1;33m" # bold; yellow
	echo -n " !     WARNING: "
	# indent will be fed from stdin
	# we tee to FD 5, which is linked to STDOUT, and capture the real stdout into the warnings array
	# we must cat in the process substitution to read the remaining lines, because head only reads one line, and then the pipe would close, leading tee to fail
	indent no_first_line_indent " !     " | tee >(head -n1 >> "$_captured_warnings_file"; cat > /dev/null)
	echo -e "\033[0m" # reset style
}

warning_inline() {
	# send all of our output to stderr
	exec 1>&2
	# if arguments are given, redirect them to stdin
	# this allows the funtion to be invoked with a string argument, or with stdin, e.g. via <<-EOF
	(( $# )) && exec <<< "$@"
	echo -n -e "\033[1;33m" # bold; yellow
	echo -n " !     WARNING: "
	# indent will be fed from stdin
	# we tee to FD 5, which is linked to STDOUT, and capture the real stdout into the warnings array
	# we must cat in the process substitution to read the remaining lines, because head only reads one line, and then the pipe would close, leading tee to fail
	indent no_first_line_indent " !     " | tee >(head -n1 >> "$_captured_warnings_file"; cat > /dev/null)
	echo -n -e "\033[0m" # reset style
}

status() {
	# send all of our output to stderr
	exec 1>&2
	# if arguments are given, redirect them to stdin
	# this allows the funtion to be invoked with a string argument, or with stdin, e.g. via <<-EOF
	(( $# )) && exec <<< "$@"
	echo -n "-----> "
	# this will be fed from stdin
	cat
}

notice() {
	# send all of our output to stderr
	exec 1>&2
	# if arguments are given, redirect them to stdin
	# this allows the funtion to be invoked with a string argument, or with stdin, e.g. via <<-EOF
	(( $# )) && exec <<< "$@"
	echo
	echo -n -e "\033[1;33m" # bold; yellow
	echo -n "       NOTICE: "
	echo -n -e "\033[0m" # reset style
	# this will be fed from stdin
	indent no_first_line_indent
	echo
}

notice_inline() {
	# send all of our output to stderr
	exec 1>&2
	# if arguments are given, redirect them to stdin
	# this allows the funtion to be invoked with a string argument, or with stdin, e.g. via <<-EOF
	(( $# )) && exec <<< "$@"
	echo -n -e "\033[1;33m" # bold; yellow
	echo -n "       NOTICE: "
	echo -n -e "\033[0m" # reset style
	# this will be fed from stdin
	indent no_first_line_indent
}

# sed -l basically makes sed replace and buffer through stdin to stdout
# so you get updates while the command runs and dont wait for the end
# e.g. npm install | indent
indent() {
	# if any value (e.g. a non-empty string, or true, or false) is given for the first argument, this will act as a flag indicating we shouldn't indent the first line; we use :+ to tell SED accordingly if that parameter is set, otherwise null string for no range selector prefix (it selects from line 2 onwards and then every 1st line, meaning all lines)
	# if the first argument is an empty string, it's the same as no argument (useful if a second argument is passed)
	# the second argument is the prefix to use for indenting; defaults to seven space characters, but can be set to e.g. " !     " to decorate each line of an error message
	local c="${1:+"2,999"} s/^/${2-"       "}/"
	case $(uname) in
		Darwin) sed -l "$c";; # mac/bsd sed: -l buffers on line boundaries
		*)      sed -u "$c";; # unix/gnu sed: -u unbuffered (arbitrary) chunks of data
	esac
}

export_env_dir() {
	local env_dir=$1
	local whitelist_regex=${2:-''}
	local blacklist_regex=${3:-'^(PATH|GIT_DIR|CPATH|CPPATH|LD_PRELOAD|LIBRARY_PATH|IFS)$'}
	if [ -d "$env_dir" ]; then
		for e in $(ls $env_dir); do
			echo "$e" | grep -E "$whitelist_regex" | grep -qvE "$blacklist_regex" &&
			export "$e=$(cat $env_dir/$e)"
			:
		done
	fi
}

curl_retry_on_18() {
	local ec=18;
	local attempts=0;
	while (( ec == 18 && attempts++ < 3 )); do
		curl "$@" # -C - would return code 33 if unsupported by server
		ec=$?
	done
	return $ec
}

err_trap() {
	error <<-EOF
		An unknown internal error occurred.
	
		Contact Heroku Support for assistance if this problem persists.
		
		Stack trace follows for debugging purposes:
		$(
			local frame=0
			while caller $frame; do
				((frame++));
			done
		)
	EOF
}

install_brotli() {
    command="nginx -v"
    nginxv=$( ${command} 2>&1 )
    NGINX_VERSION=$(echo $nginxv | grep -o '[0-9.]*$')
    echo "=== Check the nginx version: $NGINX_VERSION ==="

    root_dir="$1/_nginx"
    OUT_PREFIX="/app/.heroku/php"
    ETC=${OUT_PREFIX}/etc
    VAR=${OUT_PREFIX}/var

    mkdir ${root_dir}

    cd ${root_dir}
    wget https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz
    tar zxvf nginx-$NGINX_VERSION.tar.gz
    rm nginx-$NGINX_VERSION.tar.gz

    echo "=== Load nginx-$NGINX_VERSION ==="

    cd ${root_dir}
    git clone https://github.com/google/ngx_brotli.git
    cd ${root_dir}/ngx_brotli
    git submodule update --init
    cd ${root_dir}

    echo "=== Load ngx_brotli ==="

    cd ${root_dir}/nginx-$NGINX_VERSION

    echo "=== To try configure... ==="

    if [ -d ${root_dir}/ngx_brotli ]
    then
    echo "cinfigure brotli dir: $root_dir/ngx_brotli"
    ./configure \
        --prefix=${OUT_PREFIX} \
        --conf-path=${ETC}/nginx/nginx.conf \
        --pid-path=${VAR}/run/nginx.pid \
        --lock-path=${VAR}/run/nginx.lock \
        --http-client-body-temp-path=${VAR}/run/nginx/client_body_temp \
        --http-proxy-temp-path=${VAR}/run/nginx/proxy_temp \
        --http-fastcgi-temp-path=${VAR}/run/nginx/fastcgi_temp \
        --http-uwsgi-temp-path=${VAR}/run/nginx/uwsgi_temp \
        --http-scgi-temp-path=${VAR}/run/nginx/scgi_temp \
        --http-log-path=${VAR}/log/nginx/access.log \
        --error-log-path=${VAR}/log/nginx/error.log \
        --with-http_realip_module \
        --with-http_ssl_module \
        --add-dynamic-module=${root_dir}/ngx_brotli

    echo "=== To try make modules ==="
    make
    make install
    else
    echo "dir is not exists: $root_dir/ngx_brotli"
    fi

    cd ${root_dir}
    cd ..
    rm -R ${root_dir}
}
