/* Actual adapter + actual dimming core, synthetic transport only. */
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include "noblesse-calibration.h"

static const unsigned char synthetic_mtp[34] = {
	0,46,46,83,89,90,91,86,85,88,64,62,67,72,70,76,90,90,94,84,89,92,59,72,69,106,116,107,42,42,58,0,2,50
}; /* Published Samsung fallback bytes, synthetic fixture only, never live data. */
struct mock {
	bool held;
	int begin_error, on_error, off_error, fault_read, read_result;
	unsigned int begins, ends, reads, writes, used;
	unsigned char id[3], base, mtp[46];
	unsigned char sequence[8];
};
static unsigned int create_calls, tests;
static struct mock *creating;
int __real_nd_create(const struct nd_input *, struct nd_context **);
int __wrap_nd_create(const struct nd_input *in, struct nd_context **out)
{
	create_calls++;
	assert(creating && !creating->held && creating->writes==2 && creating->ends==1);
	return __real_nd_create(in,out); /* Full real math, not a simulated result. */
}
static void mark(struct mock *m,unsigned char value)
{ assert(m->used<sizeof(m->sequence));m->sequence[m->used++]=value; }
static int begin(void *cookie)
{
	struct mock *m=cookie;
	assert(!m->held);m->begins++;mark(m,'L');
	if(m->begin_error)return m->begin_error;
	m->held=true;return 0;
}
static void end(void *cookie)
{
	struct mock *m=cookie;
	assert(m->held);m->held=false;m->ends++;mark(m,'U');
}
static int write_packet(void *cookie,enum np_packet type,const np_u8 *data,size_t len)
{
	struct mock *m=cookie;
	assert(m->held && type==NP_LONG && len==3 && data[0]==0xf0);
	m->writes++;
	if(m->writes==1) {
		assert(data[1]==0x5a && data[2]==0x5a);mark(m,'O');return m->on_error;
	}
	assert(m->writes==2 && data[1]==0xa5 && data[2]==0xa5);
	mark(m,'F');return m->off_error;
}
static int read_packet(void *cookie,unsigned int type,np_u8 reg,size_t len,np_u8 *buf)
{
	struct mock *m=cookie;
	size_t received=len;
	int ret=(int)len;
	const unsigned char *data;
	unsigned char vbias[8]={0,1,2,3,4,5,6,0};
	assert(m->held && m->writes==1 && type==0x06);
	m->reads++;
	if(m->reads==1){assert(reg==0x04 && len==3);data=m->id;}
	else if(m->reads==2){assert(reg==0xba && len==8);vbias[7]=m->base;data=vbias;}
	else {assert(m->reads==3 && reg==0xc8 && len==46);data=m->mtp;}
	mark(m,reg);
	if(m->fault_read==(int)m->reads) {
		ret=m->read_result;
		if(ret<0)received=0;
		else if((size_t)ret<len)received=(size_t)ret;
	}
	/* Honour bounded transport contract even when simulating an oversized return.
	 * This does NOT model or repair legacy DSIM's pre-return overflow. */
	assert(received<=len);memcpy(buf,data,received);
	return ret;
}
static struct nc_requirements requirements(void)
{
	struct nc_requirements r={NP_SDC,true,true,{0x40,0x64,0x83}};
	return r;
}
static struct nc_io init_mock(struct mock *m)
{
	struct nc_io io={m,begin,end,write_packet,read_packet};
	memset(m,0,sizeof(*m));memcpy(m->id,requirements().expected_id,3);
	m->base=100;memcpy(m->mtp,synthetic_mtp,34);
	memset(m->mtp+34,0xe7,12); /* Must not become gamma input. */
	creating=m;
	return io;
}
static void zero_snapshot(const struct nc_snapshot *s)
{
	struct nc_snapshot zero;
	memset(&zero,0,sizeof(zero));assert(!memcmp(s,&zero,sizeof(zero)));
}
static void failure_read(int at,int result,int error,enum nc_stage stage)
{
	struct mock m;
	struct nc_requirements r=requirements();
	struct nc_io io=init_mock(&m);
	struct nc_snapshot snap;
	struct nc_status status;
	struct nd_context *ctx=(void*)1;
	unsigned int before=create_calls;
	m.fault_read=at;m.read_result=result;memset(&snap,0xa5,sizeof(snap));
	assert(nc_read_snapshot(&r,&io,&snap,&status)==error);
	assert(status.error==error && status.failed_at==stage && status.cleanup_error==0);
	zero_snapshot(&snap);
	assert(m.reads==(unsigned int)at && m.writes==2 && m.begins==1 && m.ends==1 && !m.held);
	io=init_mock(&m);m.fault_read=at;m.read_result=result;
	assert(nc_read_create(&r,&io,&ctx,&status)==error && ctx==NULL && create_calls==before);
	assert(!m.held && m.ends==1);tests++;
}
int main(void)
{
	struct mock m;
	struct nc_io io;
	struct nc_requirements r=requirements(),bad;
	struct nc_snapshot snap;
	struct nc_status status;
	struct nd_context *ctx,*direct;
	struct nd_input input;
	struct nd_frame actual,expected;
	unsigned int br,hop,rev,i,before;
	const unsigned char order[]={'L','O',0x04,0xba,0xc8,'F','U'};
	int at,n;
	const int lengths[]={3,8,46};
	const enum nc_stage stages[]={NC_ID,NC_VBIAS,NC_MTP};
	for(rev=2;rev<=4;rev++) {
		io=init_mock(&m);r.expected_id[2]=(unsigned char)(0x80|rev);m.id[2]=r.expected_id[2];
		assert(nc_read_snapshot(&r,&io,&snap,&status)==0 && snap.complete);
		assert(status.error==0 && status.failed_at==NC_NONE);
		assert(m.used==sizeof(order) && !memcmp(order,m.sequence,sizeof(order)));
		assert(!memcmp(snap.id,m.id,3) && snap.base_vbias==m.base && !memcmp(snap.mtp,synthetic_mtp,34));
		io=init_mock(&m);m.id[2]=r.expected_id[2];
		before=create_calls;assert(nc_read_create(&r,&io,&ctx,&status)==0 && create_calls==before+1);
		memset(&input,0,sizeof(input));input.large_panel_verified=true;
		input.id_read_ok=input.vbias_read_ok=input.mtp_read_ok=true;
		memcpy(input.id,m.id,3);input.base_vbias=m.base;input.mtp=m.mtp;input.mtp_len=34;
		assert(__real_nd_create(&input,&direct)==0);
		for(br=0;br<=100;br++)for(hop=0;hop<2;hop++) {
			assert(nd_prepare(ctx,br,hop,0x19,&actual)==0);
			assert(nd_prepare(direct,br,hop,0x19,&expected)==0);
			assert(!memcmp(&actual,&expected,sizeof(actual)));tests++;
		}
		nd_destroy(ctx);nd_destroy(direct);
	}
	r=requirements();
	/* Every short return, oversized returns and distinct transport errors. */
	for(at=1;at<=3;at++) {
		for(n=0;n<lengths[at-1];n++)failure_read(at,n,-EMSGSIZE,stages[at-1]);
		failure_read(at,lengths[at-1]+1,-EMSGSIZE,stages[at-1]);
		failure_read(at,INT_MAX,-EMSGSIZE,stages[at-1]);
		failure_read(at,-EIO,-EIO,stages[at-1]);
		failure_read(at,-ETIMEDOUT,-ETIMEDOUT,stages[at-1]);
	}
	io=init_mock(&m);m.begin_error=-EBUSY;before=create_calls;ctx=(void*)1;
	assert(nc_read_create(&r,&io,&ctx,&status)==-EBUSY && ctx==NULL && status.failed_at==NC_BEGIN);
	assert(m.begins==1 && m.writes==0 && m.reads==0 && m.ends==0 && create_calls==before);
	io=init_mock(&m);m.on_error=-EIO;
	assert(nc_read_create(&r,&io,&ctx,&status)==-EIO && ctx==NULL && status.failed_at==NC_KEY_ON);
	assert(m.writes==2 && m.reads==0 && m.ends==1);
	io=init_mock(&m);m.off_error=-EPIPE;before=create_calls;
	assert(nc_read_create(&r,&io,&ctx,&status)==-EPIPE && ctx==NULL && status.failed_at==NC_KEY_OFF);
	assert(status.cleanup_error==-EPIPE && m.ends==1 && create_calls==before);
	io=init_mock(&m);m.on_error=-EIO;m.off_error=-EPIPE;
	assert(nc_read_create(&r,&io,&ctx,&status)==-EIO && status.failed_at==NC_KEY_ON && status.cleanup_error==-EPIPE);
	io=init_mock(&m);m.fault_read=2;m.read_result=-ETIMEDOUT;m.off_error=-EPIPE;
	assert(nc_read_create(&r,&io,&ctx,&status)==-ETIMEDOUT && status.failed_at==NC_VBIAS && status.cleanup_error==-EPIPE);
	for(i=0;i<3;i++) {
		io=init_mock(&m);m.id[i]^=1;before=create_calls;
		assert(nc_read_create(&r,&io,&ctx,&status)==-ENODEV && ctx==NULL && status.failed_at==NC_ID_MATCH);
		assert(m.reads==1 && m.writes==2 && m.ends==1 && create_calls==before);
	}
#define GATE(field,value,error) do { \
	io=init_mock(&m);bad=r;bad.field=value;ctx=(void*)1; \
	assert(nc_read_create(&bad,&io,&ctx,&status)==error && ctx==NULL); \
	assert(m.begins==0 && m.writes==0 && m.reads==0 && m.ends==0); \
} while(0)
	GATE(variant,NP_BOE,-ENODEV);GATE(variant,NP_UNCONFIRMED,-ENODEV);
	GATE(large_panel_verified,false,-ENODEV);GATE(transport_ready,false,-EAGAIN);
	GATE(expected_id[0],0x41,-ENODEV);
#undef GATE
	io=init_mock(&m);io.read=NULL;assert(nc_read_create(&r,&io,&ctx,&status)==-EINVAL && !ctx && m.used==0);
	io=init_mock(&m);io.write=NULL;assert(nc_read_create(&r,&io,&ctx,&status)==-EINVAL && !ctx && m.used==0);
	io=init_mock(&m);io.begin=NULL;assert(nc_read_create(&r,&io,&ctx,&status)==-EINVAL && !ctx && m.used==0);
	io=init_mock(&m);io.end=NULL;assert(nc_read_create(&r,&io,&ctx,&status)==-EINVAL && !ctx && m.used==0);
	io=init_mock(&m);assert(nc_read_snapshot(&r,&io,NULL,&status)==-EINVAL && m.used==0);
	assert(nc_read_create(&r,&io,NULL,&status)==-EINVAL && m.used==0);
	assert(nc_read_create(NULL,&io,&ctx,&status)==-EINVAL && !ctx && m.used==0);
	assert(nc_read_create(&r,NULL,&ctx,&status)==-EINVAL && !ctx && m.used==0);
	/* All-zero/all-FF read success still must not produce a usable dimming context. */
	for(i=0;i<2;i++) {
		io=init_mock(&m);memset(m.mtp,i?255:0,46);before=create_calls;
		assert(nc_read_create(&r,&io,&ctx,&status)==-ENODATA && ctx==NULL && status.failed_at==NC_DIMMING);
		assert(m.writes==2 && m.ends==1 && create_calls==before+1);
	}
	/* A failed attempt cannot leak an earlier complete snapshot into the retry. */
	io=init_mock(&m);assert(nc_read_snapshot(&r,&io,&snap,NULL)==0 && snap.complete);
	io=init_mock(&m);m.fault_read=3;m.read_result=33;
	assert(nc_read_snapshot(&r,&io,&snap,NULL)==-EMSGSIZE);zero_snapshot(&snap);
	io=init_mock(&m);assert(nc_read_snapshot(&r,&io,&snap,NULL)==0 && snap.complete);
	printf("PASS %u numbered comparisons/length cases plus identity, lock/key errors, cleanup precedence, gates, nulls and retries\n",tests);
	return 0;
}
