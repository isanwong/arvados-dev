#!/bin/bash

read -rd "\000" helpmessage <<EOF
$(basename $0): Install and test Arvados components.

Exit non-zero if any tests fail.

Syntax:
        $(basename $0) WORKSPACE=/path/to/arvados [options]

Options:

--skip FOO     Do not test the FOO component.
--only FOO     Do not test anything except the FOO component.
--leave-temp   Do not remove GOPATH, virtualenv, and other temp dirs at exit.
               Instead, show which directories were used this time so they
               can be reused in subsequent invocations.
--skip-install Do not run any install steps. Just run tests.
               You should provide GOPATH, GEMHOME, and VENVDIR options
               from a previous invocation if you use this option.
WORKSPACE=path Arvados source tree to test.
CONFIGSRC=path Dir with api server config files to copy into source tree.
               (If none given, leave config files alone in source tree.)
services/api_test="TEST=test/functional/arvados/v1/collections_controller_test.rb"
               Restrict apiserver tests to the given file
sdk/python_test="--test-suite test.test_keep_locator"
               Restrict Python SDK tests to the given class
apps/workbench_test="TEST=test/integration/pipeline_instances_test.rb"
               Restrict Workbench tests to the given file
ARVADOS_DEBUG=1
               Print more debug messages
envvar=value   Set \$envvar to value. Primarily useful for WORKSPACE,
               *_test, and other examples shown above.

Assuming --skip-install is not given, all components are installed
into \$GOPATH, \$VENDIR, and \$GEMHOME before running any tests. Many
test suites depend on other components being installed, and installing
everything tends to be quicker than debugging dependencies.

As a special concession to the current CI server config, CONFIGSRC
defaults to $HOME/arvados-api-server if that directory exists.

More information and background:

https://arvados.org/projects/arvados/wiki/Running_tests

Available tests:

apps/workbench
apps/workbench_benchmark
apps/workbench_profile
doc
services/api
services/crunchstat
services/fuse
services/keepproxy
services/keepstore
services/nodemanager
services/arv-git-httpd
sdk/cli
sdk/python
sdk/ruby
sdk/go/arvadosclient
sdk/go/keepclient
sdk/go/streamer

EOF

# First make sure to remove any ARVADOS_ variables from the calling
# environment that could interfere with the tests.
unset $(env | cut -d= -f1 | grep \^ARVADOS_)

# Reset other variables that could affect our [tests'] behavior by
# accident.
GITDIR=
GOPATH=
VENVDIR=
PYTHONPATH=
GEMHOME=

COLUMNS=80

leave_temp=
skip_install=

declare -A leave_temp
clear_temp() {
    leaving=""
    for var in VENVDIR GOPATH GITDIR GEMHOME
    do
        if [[ -z "${leave_temp[$var]}" ]]
        then
            if [[ -n "${!var}" ]]
            then
                rm -rf "${!var}"
            fi
        else
            leaving+=" $var=\"${!var}\""
        fi
    done
    if [[ -n "$leaving" ]]; then
        echo "Leaving behind temp dirs: $leaving"
    fi
}

fatal() {
    clear_temp
    echo >&2 "Fatal: $* in ${FUNCNAME[1]} at ${BASH_SOURCE[1]} line ${BASH_LINENO[0]}"
    exit 1
}

report_outcomes() {
    for x in "${successes[@]}"
    do
        echo "Pass: $x"
    done

    if [[ ${#failures[@]} == 0 ]]
    then
        echo "All test suites passed."
    else
        echo "Failures (${#failures[@]}):"
        for x in "${failures[@]}"
        do
            echo "Fail: $x"
        done
    fi
}

exit_cleanly() {
    trap - INT
    rotate_logfile "$WORKSPACE/apps/workbench/log/" "test.log"
    stop_api
    rotate_logfile "$WORKSPACE/services/api/log/" "test.log"
    report_outcomes
    clear_temp
    exit ${#failures}
}

sanity_checks() {
  # Make sure WORKSPACE is set
  if ! [[ -n "$WORKSPACE" ]]; then
    echo >&2 "$helpmessage"
    echo >&2
    echo >&2 "Error: WORKSPACE environment variable not set"
    echo >&2
    exit 1
  fi

  # Make sure virtualenv is installed
  `virtualenv --help >/dev/null 2>&1`

  if [[ "$?" != "0" ]]; then
    echo >&2
    echo >&2 "Error: virtualenv could not be found"
    echo >&2
    exit 1
  fi

  # Make sure go is installed
  `go env >/dev/null 2>&1`

  if [[ "$?" != "0" ]]; then
    echo >&2
    echo >&2 "Error: go could not be found"
    echo >&2
    exit 1
  fi

  # Make sure gcc is installed
  `gcc --help >/dev/null 2>&1`

  if [[ "$?" != "0" ]]; then
    echo >&2
    echo >&2 "Error: gcc could not be found"
    echo >&2
    exit 1
  fi
}

rotate_logfile() {
  # $BUILD_NUMBER is set by Jenkins if this script is being called as part of a Jenkins run
  if [[ -f "$1/$2" ]]; then
    THEDATE=`date +%Y%m%d%H%M%S`
    mv "$1/$2" "$1/$THEDATE-$BUILD_NUMBER-$2"
    gzip "$1/$THEDATE-$BUILD_NUMBER-$2"
  fi
}

declare -a failures
declare -A skip
declare -A testargs
skip[apps/workbench_profile]=1

while [[ -n "$1" ]]
do
    arg="$1"; shift
    case "$arg" in
        --help)
            echo >&2 "$helpmessage"
            echo >&2
            exit 1
            ;;
        --skip)
            skipwhat="$1"; shift
            skip[$skipwhat]=1
            ;;
        --only)
            only="$1"; skip[$1]=""; shift
            ;;
        --skip-install)
            skip_install=1
            ;;
        --leave-temp)
            leave_temp[VENVDIR]=1
            leave_temp[GOPATH]=1
            leave_temp[GEMHOME]=1
            ;;
        --retry)
            retry=1
            ;;
        *_test=*)
            suite="${arg%%_test=*}"
            args="${arg#*=}"
            testargs["$suite"]="$args"
            ;;
        *=*)
            eval export $(echo $arg | cut -d= -f1)=\"$(echo $arg | cut -d= -f2-)\"
            ;;
        *)
            echo >&2 "$0: Unrecognized option: '$arg'. Try: $0 --help"
            exit 1
            ;;
    esac
done

start_api() {
    echo 'Starting API server...'
    cd "$WORKSPACE" \
        && eval $(python sdk/python/tests/run_test_server.py start --auth admin) \
        && export ARVADOS_TEST_API_HOST="$ARVADOS_API_HOST" \
        && export ARVADOS_TEST_API_INSTALLED="$$" \
        && (env | egrep ^ARVADOS)
}

stop_api() {
    if [[ -n "$ARVADOS_TEST_API_HOST" ]]; then
        unset ARVADOS_TEST_API_HOST
        cd "$WORKSPACE" \
            && python sdk/python/tests/run_test_server.py stop
    fi
}

interrupt() {
    failures+=("($(basename $0) interrupted)")
    exit_cleanly
}
trap interrupt INT

sanity_checks

echo "WORKSPACE=$WORKSPACE"

if [[ -z "$CONFIGSRC" ]] && [[ -d "$HOME/arvados-api-server" ]]; then
    # Jenkins expects us to use this by default.
    CONFIGSRC="$HOME/arvados-api-server"
fi

# Clean up .pyc files that may exist in the workspace
cd "$WORKSPACE"
find -name '*.pyc' -delete

# Set up temporary install dirs (unless existing dirs were supplied)
for tmpdir in VENVDIR GOPATH GEMHOME
do
    if [[ -n "${!tmpdir}" ]]; then
        leave_temp[$tmpdir]=1
    else
        eval $tmpdir=$(mktemp -d)
    fi
done

setup_ruby_environment() {
    if [[ -s "$HOME/.rvm/scripts/rvm" ]] ; then
      source "$HOME/.rvm/scripts/rvm"
      using_rvm=true
    elif [[ -s "/usr/local/rvm/scripts/rvm" ]] ; then
      source "/usr/local/rvm/scripts/rvm"
      using_rvm=true
    else
      using_rvm=false
    fi

    if [[ "$using_rvm" == true ]]; then
        # If rvm is in use, we can't just put separate "dependencies"
        # and "gems-under-test" paths to GEM_PATH: passenger resets
        # the environment to the "current gemset", which would lose
        # our GEM_PATH and prevent our test suites from running ruby
        # programs (for example, the Workbench test suite could not
        # boot an API server or run arv). Instead, we have to make an
        # rvm gemset and use it for everything.

        [[ `type rvm | head -n1` == "rvm is a function" ]] \
            || fatal 'rvm check'

        # Put rvm's favorite path back in first place (overriding
        # virtualenv, which just put itself there). Ignore rvm's
        # complaint about not being in first place already.
        rvm use @default 2>/dev/null

        # Create (if needed) and switch to an @arvados-tests
        # gemset. (Leave the choice of ruby to the caller.)
        rvm use @arvados-tests --create \
            || fatal 'rvm gemset setup'

        rvm env
    else
        # When our "bundle install"s need to install new gems to
        # satisfy dependencies, we want them to go where "gem install
        # --user-install" would put them. (However, if the caller has
        # already set GEM_HOME, we assume that's where dependencies
        # should be installed, and we should leave it alone.)

        if [ -z "$GEM_HOME" ]; then
            user_gempath="$(gem env gempath)"
            export GEM_HOME="${user_gempath%%:*}"
        fi
        PATH="$(gem env gemdir)/bin:$PATH"

        # When we build and install our own gems, we install them in our
        # $GEMHOME tmpdir, and we want them to be at the front of GEM_PATH and
        # PATH so integration tests prefer them over other versions that
        # happen to be installed in $user_gempath, system dirs, etc.

        tmpdir_gem_home="$(env - PATH="$PATH" HOME="$GEMHOME" gem env gempath | cut -f1 -d:)"
        PATH="$tmpdir_gem_home/bin:$PATH"
        export GEM_PATH="$tmpdir_gem_home:$(gem env gempath)"

        echo "Will install dependencies to $(gem env gemdir)"
        echo "Will install arvados gems to $tmpdir_gem_home"
        echo "Gem search path is GEM_PATH=$GEM_PATH"
    fi
}

with_test_gemset() {
    if [[ "$using_rvm" == true ]]; then
        "$@"
    else
        GEM_HOME="$tmpdir_gem_home" "$@"
    fi
}

export GOPATH
mkdir -p "$GOPATH/src/git.curoverse.com"
ln -sfn "$WORKSPACE" "$GOPATH/src/git.curoverse.com/arvados.git" \
    || fatal "symlink failed"

virtualenv --setuptools "$VENVDIR" || fatal "virtualenv $VENVDIR failed"
. "$VENVDIR/bin/activate"

# Note: this must be the last time we change PATH, otherwise rvm will
# whine a lot.
setup_ruby_environment

echo "PATH is $PATH"

if ! which bundler >/dev/null
then
    gem install --user-install bundler || fatal 'Could not install bundler'
fi

# Needed for run_test_server.py which is used by certain (non-Python) tests.
echo "pip install -q PyYAML"
pip install -q PyYAML || fatal "pip install PyYAML failed"

checkexit() {
    if [[ "$1" != "0" ]]; then
        title "!!!!!! $2 FAILED !!!!!!"
        failures+=("$2 (`timer`)")
    else
        successes+=("$2 (`timer`)")
    fi
}

timer_reset() {
    t0=$SECONDS
}

timer() {
    echo -n "$(($SECONDS - $t0))s"
}

do_test() {
    while ! do_test_once ${@} && [[ "$retry" == 1 ]]
    do
        read -p 'Try again? [Y/n] ' x
        if [[ "$x" != "y" ]] && [[ "$x" != "" ]]
        then
            break
        fi
    done
}

do_test_once() {
    if [[ -z "${skip[$1]}" ]] && ( [[ -z "$only" ]] || [[ "$only" == "$1" ]] )
    then
        title "Running $1 tests"
        timer_reset
        if [[ "$2" == "go" ]]
        then
            go test ${testargs[$1]} "git.curoverse.com/arvados.git/$1"
        elif [[ "$2" == "pip" ]]
        then
           cd "$WORKSPACE/$1" \
                && python setup.py test ${testargs[$1]}
        elif [[ "$2" != "" ]]
        then
            "test_$2"
        else
            "test_$1"
        fi
        result="$?"
        checkexit $result "$1 tests"
        title "End of $1 tests (`timer`)"
        return $result
    else
        title "Skipping $1 tests"
    fi
}

do_install() {
    if [[ -z "$skip_install" ]]
    then
        title "Running $1 install"
        timer_reset
        if [[ "$2" == "go" ]]
        then
            go get -t "git.curoverse.com/arvados.git/$1"
        elif [[ "$2" == "pip" ]]
        then
            cd "$WORKSPACE/$1" \
                && python setup.py sdist rotate --keep=1 --match .tar.gz \
                && pip install -q --upgrade dist/*.tar.gz
        elif [[ "$2" != "" ]]
        then
            "install_$2"
        else
            "install_$1"
        fi
        checkexit $? "$1 install"
        title "End of $1 install (`timer`)"
    else
        title "Skipping $1 install"
    fi
}

title () {
    txt="********** $1 **********"
    printf "\n%*s%s\n\n" $((($COLUMNS-${#txt})/2)) "" "$txt"
}

bundle_install_trylocal() {
    (
        set -e
        echo "(Running bundle install --local. 'could not find package' messages are OK.)"
        if ! bundle install --local --no-deployment; then
            echo "(Running bundle install again, without --local.)"
            bundle install --no-deployment
        fi
        bundle package --all
    )
}

install_doc() {
    cd "$WORKSPACE/doc" \
        && bundle_install_trylocal \
        && rm -rf .site
}
do_install doc

install_ruby_sdk() {
    with_test_gemset gem uninstall --force --all --executables arvados \
        && cd "$WORKSPACE/sdk/ruby" \
        && bundle_install_trylocal \
        && gem build arvados.gemspec \
        && with_test_gemset gem install --no-ri --no-rdoc `ls -t arvados-*.gem|head -n1`
}
do_install sdk/ruby ruby_sdk

install_cli() {
    with_test_gemset gem uninstall --force --all --executables arvados-cli \
        && cd "$WORKSPACE/sdk/cli" \
        && bundle_install_trylocal \
        && gem build arvados-cli.gemspec \
        && with_test_gemset gem install --no-ri --no-rdoc `ls -t arvados-cli-*.gem|head -n1`
}
do_install sdk/cli cli

# Install the Python SDK early. Various other test suites (like
# keepproxy) bring up run_test_server.py, which imports the arvados
# module. We can't actually *test* the Python SDK yet though, because
# its own test suite brings up some of those other programs (like
# keepproxy).
declare -a pythonstuff
pythonstuff=(
    sdk/python
    services/fuse
    services/nodemanager
    )
for p in "${pythonstuff[@]}"
do
    do_install "$p" pip
done

install_apiserver() {
    cd "$WORKSPACE/services/api" \
        && RAILS_ENV=test bundle_install_trylocal

    rm -f config/environments/test.rb
    cp config/environments/test.rb.example config/environments/test.rb

    if [ -n "$CONFIGSRC" ]
    then
        for f in database.yml application.yml
        do
            cp "$CONFIGSRC/$f" config/ || fatal "$f"
        done
    fi

    # Fill in a random secret_token and blob_signing_key for testing
    SECRET_TOKEN=`echo 'puts rand(2**512).to_s(36)' |ruby`
    BLOB_SIGNING_KEY=`echo 'puts rand(2**512).to_s(36)' |ruby`

    sed -i'' -e "s:SECRET_TOKEN:$SECRET_TOKEN:" config/application.yml
    sed -i'' -e "s:BLOB_SIGNING_KEY:$BLOB_SIGNING_KEY:" config/application.yml

    # Set up empty git repo (for git tests)
    GITDIR=$(mktemp -d)
    sed -i'' -e "s:/var/cache/git:$GITDIR:" config/application.default.yml

    rm -rf $GITDIR
    mkdir -p $GITDIR/test
    cd $GITDIR/test \
        && git init \
        && git config user.email "jenkins@ci.curoverse.com" \
        && git config user.name "Jenkins, CI" \
        && touch tmp \
        && git add tmp \
        && git commit -m 'initial commit'

    # Clear out any lingering postgresql connections to arvados_test, so that we can drop it
    # This assumes the current user is a postgresql superuser
    psql arvados_test -c "SELECT pg_terminate_backend (pg_stat_activity.procpid::int) FROM pg_stat_activity WHERE pg_stat_activity.datname = 'arvados_test';" 2>/dev/null

    cd "$WORKSPACE/services/api" \
        && RAILS_ENV=test bundle exec rake db:drop \
        && RAILS_ENV=test bundle exec rake db:setup \
        && RAILS_ENV=test bundle exec rake db:fixtures:load
}
do_install services/api apiserver

declare -a gostuff
gostuff=(
    services/arv-git-httpd
    services/crunchstat
    services/keepstore
    services/keepproxy
    sdk/go/arvadosclient
    sdk/go/keepclient
    sdk/go/streamer
    )
for g in "${gostuff[@]}"
do
    do_install "$g" go
done

install_workbench() {
    cd "$WORKSPACE/apps/workbench" \
        && mkdir -p tmp/cache \
        && RAILS_ENV=test bundle_install_trylocal
}
do_install apps/workbench workbench

test_doclinkchecker() {
    (
        set -e
        cd "$WORKSPACE/doc"
        ARVADOS_API_HOST=qr1hi.arvadosapi.com
        # Make sure python-epydoc is installed or the next line won't
        # do much good!
        PYTHONPATH=$WORKSPACE/sdk/python/ bundle exec rake linkchecker baseurl=file://$WORKSPACE/doc/.site/ arvados_workbench_host=workbench.$ARVADOS_API_HOST arvados_api_host=$ARVADOS_API_HOST
    )
}
do_test doc doclinkchecker

stop_api

test_apiserver() {
    cd "$WORKSPACE/services/api" \
        && RAILS_ENV=test bundle exec rake test TESTOPTS=-v ${testargs[services/api]}
}
do_test services/api apiserver

# Shortcut for when we're only running apiserver tests. This saves a bit of time,
# because we don't need to start up the api server for subsequent tests.
if [ ! -z "$only" ] && [ "$only" == "services/api" ]; then
  rotate_logfile "$WORKSPACE/services/api/log/" "test.log"
  exit_cleanly
fi

start_api

test_ruby_sdk() {
    cd "$WORKSPACE/sdk/ruby" \
        && bundle exec rake test TESTOPTS=-v ${testargs[sdk/ruby]}
}
do_test sdk/ruby ruby_sdk

test_cli() {
    cd "$WORKSPACE/sdk/cli" \
        && mkdir -p /tmp/keep \
        && KEEP_LOCAL_STORE=/tmp/keep bundle exec rake test TESTOPTS=-v ${testargs[sdk/cli]}
}
do_test sdk/cli cli

for p in "${pythonstuff[@]}"
do
    do_test "$p" pip
done

for g in "${gostuff[@]}"
do
    do_test "$g" go
done

test_workbench() {
    cd "$WORKSPACE/apps/workbench" \
        && RAILS_ENV=test bundle exec rake test TESTOPTS=-v ${testargs[apps/workbench]}
}
do_test apps/workbench workbench

test_workbench_benchmark() {
    cd "$WORKSPACE/apps/workbench" \
        && RAILS_ENV=test bundle exec rake test:benchmark ${testargs[apps/workbench_benchmark]}
}
do_test apps/workbench_benchmark workbench_benchmark

test_workbench_profile() {
    cd "$WORKSPACE/apps/workbench" \
        && RAILS_ENV=test bundle exec rake test:profile ${testargs[apps/workbench_profile]}
}
do_test apps/workbench_profile workbench_profile

exit_cleanly
