#include "discovery.h"
#include "protocol.h"

#include <stdlib.h>

#ifdef HAVE_DNSSD

#include <arpa/inet.h>
#include <dns_sd.h>

struct obscam_discovery {
	DNSServiceRef ref;
};

static void DNSSD_API register_reply(DNSServiceRef ref, DNSServiceFlags flags, DNSServiceErrorType err,
				     const char *name, const char *type, const char *domain, void *ctx)
{
	(void)ref;
	(void)flags;
	(void)name;
	(void)type;
	(void)domain;
	(void)ctx;
	(void)err;
}

obscam_discovery_t *obscam_discovery_register(const char *service_name, uint16_t port)
{
	struct obscam_discovery *d = calloc(1, sizeof(*d));
	if (!d)
		return NULL;

	DNSServiceErrorType err = DNSServiceRegister(&d->ref, 0, 0, service_name, OBSCAM_SERVICE_TYPE, NULL,
						     NULL, htons(port), 0, NULL, register_reply, d);
	if (err != kDNSServiceErr_NoError) {
		free(d);
		return NULL;
	}
	return d;
}

int obscam_discovery_fd(obscam_discovery_t *d)
{
	return d ? DNSServiceRefSockFD(d->ref) : -1;
}

void obscam_discovery_process(obscam_discovery_t *d)
{
	if (d)
		DNSServiceProcessResult(d->ref);
}

void obscam_discovery_unregister(obscam_discovery_t *d)
{
	if (!d)
		return;
	DNSServiceRefDeallocate(d->ref);
	free(d);
}

#else /* !HAVE_DNSSD */

obscam_discovery_t *obscam_discovery_register(const char *service_name, uint16_t port)
{
	(void)service_name;
	(void)port;
	return NULL;
}

int obscam_discovery_fd(obscam_discovery_t *d)
{
	(void)d;
	return -1;
}

void obscam_discovery_process(obscam_discovery_t *d)
{
	(void)d;
}

void obscam_discovery_unregister(obscam_discovery_t *d)
{
	(void)d;
}

#endif
