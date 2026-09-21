# gdash — install, uninstall, check.
#
# DESTDIR and PREFIX are honoured so a packager can stage this; nothing here
# assumes it is running on the machine that will serve dashboards.
#
# WHAT THIS DOES NOT DO, deliberately: create a user account, enable a unit, or
# start a service. An install that starts something is an install that
# surprises somebody. docs/gdash_operations.md says which commands to run next
# and why.

PREFIX     ?= /usr/local
DESTDIR    ?=
LIBDIR     := $(PREFIX)/lib/gdash
BINDIR     := $(PREFIX)/bin
DOCDIR     := $(PREFIX)/share/doc/gdash
UNITDIR    ?= /lib/systemd/system

# The FHS roles from design §6. These are the resolver's five, and the resolver
# is the only place they are otherwise written down.
CONFDIR    := /etc/gdash
STATEDIR   := /var/lib/gdash
CACHEDIR   := /var/cache/gdash
LOGDIR     := /var/log/gdash

INSTALL    ?= install

.PHONY: all install uninstall check test

all:
	@echo "nothing to build -- gdash is gBASIC source. Try: make install"

install:
	$(INSTALL) -d -m 0755 $(DESTDIR)$(LIBDIR)
	$(INSTALL) -m 0644 src/*.bas $(DESTDIR)$(LIBDIR)/
	$(INSTALL) -d -m 0755 $(DESTDIR)$(BINDIR)
	$(INSTALL) -m 0755 scripts/gdash.in $(DESTDIR)$(BINDIR)/gdash
	$(INSTALL) -m 0755 scripts/gdash-server.in $(DESTDIR)$(BINDIR)/gdash-server
	sed -i 's|@LIBDIR@|$(LIBDIR)|g' $(DESTDIR)$(BINDIR)/gdash $(DESTDIR)$(BINDIR)/gdash-server
	$(INSTALL) -d -m 0755 $(DESTDIR)$(UNITDIR)
	$(INSTALL) -m 0644 packaging/gdash.service $(DESTDIR)$(UNITDIR)/
	$(INSTALL) -m 0644 packaging/gdash-scheduler.service $(DESTDIR)$(UNITDIR)/
	$(INSTALL) -m 0644 packaging/gdash-scheduler.timer $(DESTDIR)$(UNITDIR)/
	# A unit that names /usr/local when the operator asked for /opt is a unit
	# that fails at start with a path nobody typed.
	sed -i 's|@BINDIR@|$(BINDIR)|g; s|@DOCDIR@|$(DOCDIR)|g' \
	    $(DESTDIR)$(UNITDIR)/gdash.service \
	    $(DESTDIR)$(UNITDIR)/gdash-scheduler.service
	# The data roles. systemd's StateDirectory= and friends create and chown
	# these for the service, but the CLI is run by an administrator before the
	# service has ever started, so they exist from the install onward.
	$(INSTALL) -d -m 0755 $(DESTDIR)$(DOCDIR)
	$(INSTALL) -m 0644 docs/gdash_operations.md $(DESTDIR)$(DOCDIR)/
	$(INSTALL) -m 0644 docs/gdash_record_format.md $(DESTDIR)$(DOCDIR)/
	$(INSTALL) -d -m 0755 $(DESTDIR)$(CONFDIR)
	$(INSTALL) -d -m 0755 $(DESTDIR)$(STATEDIR)
	$(INSTALL) -d -m 0755 $(DESTDIR)$(STATEDIR)/dashboards
	$(INSTALL) -d -m 0755 $(DESTDIR)$(CACHEDIR)
	$(INSTALL) -d -m 0755 $(DESTDIR)$(LOGDIR)
	@echo
	@echo "gdash installed. Three things remain, and none is done for you:"
	@echo "  1. create the service account:  useradd --system --no-create-home gdash"
	@echo "  2. give it the data roles:"
	@echo "       chown -R gdash:gdash $(CONFDIR) $(STATEDIR) $(CACHEDIR) $(LOGDIR)"
	@echo "     These are created root-owned above, because the account may not"
	@echo "     exist yet. Running the CLI as root before that chown leaves"
	@echo "     root-owned directories the service cannot write into (G14-1)."
	@echo "  3. read docs/gdash_operations.md, then: systemctl enable --now gdash"

# Removes what install put there AND NOTHING ELSE. The data directories are
# left alone on purpose: an uninstall that deletes dashboards is a catastrophe
# wearing a helpful face.
uninstall:
	rm -f $(DESTDIR)$(BINDIR)/gdash
	rm -f $(DESTDIR)$(BINDIR)/gdash-server
	rm -rf $(DESTDIR)$(LIBDIR)
	rm -rf $(DESTDIR)$(DOCDIR)
	rm -f $(DESTDIR)$(UNITDIR)/gdash.service
	rm -f $(DESTDIR)$(UNITDIR)/gdash-scheduler.service
	rm -f $(DESTDIR)$(UNITDIR)/gdash-scheduler.timer
	@echo
	@echo "gdash removed. Left alone, deliberately:"
	@echo "  $(CONFDIR)   your configuration"
	@echo "  $(STATEDIR)  your dashboards -- the entire backup set"
	@echo "  $(CACHEDIR)  staged data (safe to delete; it refetches)"
	@echo "  $(LOGDIR)    logs"

check test:
	tests/run_tests.sh
