//
//  Xprobe.m
//  XprobePlugin
//
//  Created by John Holdsworth on 17/05/2014.
//  Copyright (c) 2014 John Holdsworth. All rights reserved.
//
//  For full licensing term see https://github.com/johnno1962/XprobePlugin
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//  DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE
//  FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
//  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//  SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
//  CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
//  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
//  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

/*
 *  This is the source for the Xprobe memory scanner. While it connects as a client
 *  it effectively operates as a service for the Xcode browser window receiving
 *  the arguments to JavaScript "prompt()" calls. The first argument is the
 *  selector to be called in the Xprobe class. The second is an arugment 
 *  specifying the part of the page to be modified, generally the pathID 
 *  which also identifies the object the user action is related to. In 
 *  response, the selector sends back JavaScript to be executed in the
 *  browser window or, if an object has been traced, trace output.
 *
 *  The pathID is the index into the paths array which contain objects from which
 *  the object referred to can be determined rather than pass back and forward
 *  raw memory addresses. Initially, this is the number of the root object from
 *  the original search but as you browse through objects or ivars and arrays a
 *  path is built up of these objects so when the value of an ivar browsed to 
 *  changes it will be reflected in the browser when you next click on it.
 */

#import "Xprobe.h"
#import "Xtrace.h"

#import <objc/runtime.h>
#import <vector>
#import <map>

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
#import <UIKit/UIKit.h>
#else
#import <Cocoa/Cocoa.h>
#endif

// options
static BOOL logXprobeSweep = NO, retainObjects = YES;

static unsigned maxArrayItemsForGraphing = 20, currentMaxArrayIndex;

// sweep state
struct _xsweep { unsigned sequence, depth; __unsafe_unretained id from; const char *source; };

static struct _xsweep sweepState;

static std::map<__unsafe_unretained id,struct _xsweep> instancesSeen;
static std::map<__unsafe_unretained Class,std::vector<__unsafe_unretained id> > instancesByClass;

static NSMutableArray *paths;

// "dot" object graph rendering

struct _animate { NSTimeInterval lastMessageTime; unsigned sequence; BOOL highlighted; };

static std::map<__unsafe_unretained id,struct _animate> instancesLabeled;

typedef NS_OPTIONS(NSUInteger, XGraphOptions) {
    XGraphArrayWithoutLmit       = 1 << 0,
    XGraphInterconnections       = 1 << 1,
    XGraphAllObjects             = 1 << 2,
    XGraphWithoutExcepton        = 1 << 3
};

static XGraphOptions graphOptions;
static NSMutableString *dotGraph;

static BOOL graphAnimating;
static NSLock *writeLock;

@interface NSObject(Xprobe)

// forward references
- (void)xlinkForCommand:(NSString *)which withPathID:(int)pathID title:(const char *)title into:html;
- (void)xlinkForCommand:(NSString *)which withPathID:(int)pathID into:html;

- (void)xspanForPathID:(int)pathID ivar:(Ivar)ivar into:(NSMutableString *)html;
- (void)xopenWithPathID:(int)pathID into:(NSMutableString *)html;

- (NSString *)xlinkForProtocol:(NSString *)protocolName;
- (void)xsweep;

// ivar handling
- (BOOL)xvalueForIvar:(Ivar)ivar update:(NSString *)value;
- (NSString *)xtype:(const char *)type;
- (id)xvalueForMethod:(Method)method;
- (id)xvalueForIvar:(Ivar)ivar;

@end

@interface NSObject(XprobeReferences)

// external references
- (NSArray *)getNSArray;
- (NSArray *)subviews;
- (id)contentView;
- (id)document;
- (id)delegate;
- (SEL)action;
- (id)target;

@end

/*****************************************************
 ******** classes that go to make up a path **********
 *****************************************************/

@interface XprobePath : NSObject
@property int pathID;
@end

@implementation XprobePath

+ (id)withPathID:(int)pathID {
    XprobePath *path = [self new];
    path.pathID = pathID;
    return path;
}

- (int)xadd {
    int newPathID = (int)[paths count];
    [paths addObject:self];
    return newPathID;
}

- (id)object {
    return [paths[self.pathID] object];
}

- (id)aClass {
    return [[self object] class];
}

@end

// these two classes determine
// whether objects are retained

@interface XprobeRetained : XprobePath
@property (nonatomic,retain) id object;
@end

@implementation XprobeRetained
@end

@interface XprobeAssigned : XprobePath
@property (nonatomic,assign) id object;
@end

@implementation XprobeAssigned
@end

@interface XprobeIvar : XprobePath
@property const char *name;
@end

@implementation XprobeIvar

- (id)object {
    id obj = [super object];
    Ivar ivar = class_getInstanceVariable([obj class], self.name);
    return [obj xvalueForIvar:ivar];
}

@end

@interface XprobeMethod : XprobePath
@property SEL name;
@end

@implementation XprobeMethod

- (id)object {
    id obj = [super object];
    Method method = class_getInstanceMethod([obj class], self.name);
    return [obj xvalueForMethod:method];
}

@end

@interface XprobeArray : XprobePath
@property NSUInteger sub;
@end

@implementation XprobeArray

- (NSArray *)array {
    return [super object];
}

- (id)object {
    NSArray *arr = [self array];
    if ( self.sub < [arr count] )
        return arr[self.sub];
    NSLog( @"Xprobe: %@ reference %d beyond end of array %d",
          NSStringFromClass([self class]), (int)self.sub, (int)[arr count] );
    return nil;
}

@end

@interface XprobeSet : XprobeArray
@end

@implementation XprobeSet

- (NSArray *)array {
    return [[paths[self.pathID] object] allObjects];
}

@end

@interface XprobeView : XprobeArray
@end

@implementation XprobeView

- (NSArray *)array {
    return [[paths[self.pathID] object] subviews];
}

@end

@interface XprobeDict : XprobePath
@property id sub;
@end

@implementation XprobeDict

- (id)object {
    return [super object][self.sub];
}

@end

@interface XprobeSuper : XprobePath
@property Class aClass;
@end

@implementation XprobeSuper
@end

// class without instance
@interface XprobeClass : XprobeSuper
@end

@implementation XprobeClass

- (id)object {
    return self;
}

@end

@implementation NSRegularExpression(Xprobe)

+ (NSRegularExpression *)xsimpleRegexp:(NSString *)pattern {
    NSError *error = nil;
    NSRegularExpression *regexp = [[NSRegularExpression alloc] initWithPattern:pattern
                                                                       options:NSRegularExpressionCaseInsensitive
                                                                         error:&error];
    if ( error && [pattern length] )
    NSLog( @"Xprobe: Filter compilation error: %@, in pattern: \"%@\"", [error localizedDescription], pattern );
    return regexp;
}

- (BOOL)xmatches:(NSString *)str  {
    return [self rangeOfFirstMatchInString:str options:0 range:NSMakeRange(0, [str length])].location != NSNotFound;
}

@end

/*****************************************************
 ********* implmentation of Xprobe service ***********
 *****************************************************/

#import <netinet/tcp.h>
#import <sys/socket.h>
#import <arpa/inet.h>

static int clientSocket;

@implementation Xprobe

+ (NSString *)revision {
    return @"$Id: //depot/XprobePlugin/Classes/Xprobe.mm#52 $";
}

+ (BOOL)xprobeExclude:(const char *)className {
    return className[0] == '_' || strncmp(className, "WebHistory", 10) == 0 ||
        strncmp(className, "NS", 2) == 0 || strncmp(className, "XC", 2) == 0 ||
        strncmp(className, "IDE", 3) == 0 || strncmp(className, "DVT", 3) == 0 ||
        strncmp(className, "Xcode3", 6) == 0 ||strncmp(className, "IB", 2) == 0 ||
        strncmp(className, "VK", 2) == 0;
}

+ (void)connectTo:(const char *)ipAddress retainObjects:(BOOL)shouldRetain {

    retainObjects = shouldRetain;

    NSLog( @"Xprobe: Connecting to %s", ipAddress );

    if ( clientSocket ) {
        close( clientSocket );
        [NSThread sleepForTimeInterval:.5];
    }

    struct sockaddr_in loaderAddr;

    loaderAddr.sin_family = AF_INET;
	inet_aton( ipAddress, &loaderAddr.sin_addr );
	loaderAddr.sin_port = htons(XPROBE_PORT);

    int optval = 1;
    if ( (clientSocket = socket(loaderAddr.sin_family, SOCK_STREAM, 0)) < 0 )
        NSLog( @"Xprobe: Could not open socket for injection: %s", strerror( errno ) );
    else if ( setsockopt( clientSocket, IPPROTO_TCP, TCP_NODELAY, (void *)&optval, sizeof(optval)) < 0 )
        NSLog( @"Xprobe: Could not set TCP_NODELAY: %s", strerror( errno ) );
    else if ( connect( clientSocket, (struct sockaddr *)&loaderAddr, sizeof loaderAddr ) < 0 )
        NSLog( @"Xprobe: Could not connect: %s", strerror( errno ) );
    else
        [self performSelectorInBackground:@selector(service) withObject:nil];
}

+ (void)service {

    uint32_t magic = XPROBE_MAGIC;
    if ( write(clientSocket, &magic, sizeof magic ) != sizeof magic )
    return;

    [self writeString:[[NSBundle mainBundle] bundleIdentifier]];

    while ( clientSocket ) {
        NSString *command = [self readString];
        if ( !command ) break;
        NSString *argument = [self readString];
        if ( !argument ) break;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:NSSelectorFromString(command) withObject:argument];
#pragma clang diagnostic pop
    }

    NSLog( @"Xprobe: Service loop exits" );
}

+ (NSString *)readString {
    uint32_t length;

    if ( read(clientSocket, &length, sizeof length) != sizeof length ) {
        NSLog( @"Xprobe: Socket read error %s", strerror(errno) );
        return nil;
    }

    ssize_t sofar = 0, bytes;
    char *buff = (char *)malloc(length+1);

    while ( buff && sofar < length && (bytes = read(clientSocket, buff+sofar, length-sofar )) > 0 )
    sofar += bytes;

    if ( sofar < length ) {
        NSLog( @"Xprobe: Socket read error %d/%d: %s", (int)sofar, length, strerror(errno) );
        return nil;
    }

    if ( buff )
    buff[sofar] = '\000';

    NSString *str = [NSString stringWithUTF8String:buff];
    free( buff );
    return str;
}

+ (void)writeString:(NSString *)str {
    const char *data = [str UTF8String];
    uint32_t length = (uint32_t)strlen(data);

    if ( !writeLock )
        writeLock = [NSLock new];
    [writeLock lock];

    if ( !clientSocket )
        NSLog( @"Xprobe: Write to closed" );
    else if ( write(clientSocket, &length, sizeof length ) != sizeof length ||
             write(clientSocket, data, length ) != length )
        NSLog( @"Xprobe: Socket write error %s", strerror(errno) );

    [writeLock unlock];
}

static NSString *lastPattern;

+ (void)search:(NSString *)pattern {
    [self performSelectorOnMainThread:@selector(_search:) withObject:pattern waitUntilDone:NO];
}

+ (void)_search:(NSString *)pattern {

    NSLog( @"Xprobe: sweeping memory" );

    dotGraph = [NSMutableString stringWithString:@"digraph sweep {\n"
                "    node [href=\"javascript:void(click_node('\\N'))\" id=\"\\N\" fontname=\"Arial\"];\n"];

    instancesSeen.clear();
    instancesByClass.clear();
    instancesLabeled.clear();

    sweepState.sequence = sweepState.depth = 0;
    sweepState.source = "seed";

    if ( pattern != lastPattern ) {
        lastPattern = pattern;
        graphOptions = 0;
    }

    paths = [NSMutableArray new];
    [[self xprobeSeeds] xsweep];

    [dotGraph appendString:@"}\n"];
    [self writeString:dotGraph];

    dotGraph = nil;

    NSRegularExpression *classRegexp = [NSRegularExpression xsimpleRegexp:pattern];
    std::map<__unsafe_unretained id,int> matched;

    for ( const auto &byClass : instancesByClass )
        if ( !classRegexp || [classRegexp xmatches:NSStringFromClass(byClass.first)] )
            for ( const auto &instance : byClass.second )
                matched[instance]++;

    NSMutableString *html = [NSMutableString new];
    [html appendString:@"$().innerHTML = '"];

    if ( matched.empty() )
        [html appendString:@"No root objects found, check class name pattern.<br>"];
    else
        for ( int pathID=0 ; pathID<[paths count] ; pathID++ ) {
            id obj = [paths[pathID] object];

            if( matched[obj] ) {
                struct _xsweep &info = instancesSeen[obj];

                for ( unsigned i=1 ; i<info.depth ; i++ )
                    [html appendString:@"&nbsp; &nbsp; "];

                [obj xlinkForCommand:@"open" withPathID:info.sequence title:info.source into:html];
                [html appendString:@"<br>"];
            }
        }

    [html appendString:@"';"];
    [self writeString:html];

    if ( graphAnimating )
        [self animate:@"1"];
}

+ (void)regraph:(NSString *)input {
    graphOptions = [input intValue];
    [self search:lastPattern];
}

+ (void)open:(NSString *)input {
    int pathID = [input intValue];
    id obj = [paths[pathID] object];

    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('%d').outerHTML = '", pathID];
    [obj xlinkForCommand:@"close" withPathID:pathID into:html];

    [html appendString:@"<br><table><tr><td class=indent><td class=drilldown>"];
    [obj xopenWithPathID:pathID into:html];

    [html appendString:@"</table></span>';"];
    [self writeString:html];
}

+ (void)close:(NSString *)input {
    int pathID = [input intValue];
    id obj = [paths[pathID] object];

    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('%d').outerHTML = '", pathID];
    [obj xlinkForCommand:@"open" withPathID:pathID into:html];

    [html appendString:@"';"];
    [self writeString:html];
}

+ (void)properties:(NSString *)input {
    int pathID = [input intValue];
    Class aClass = [paths[pathID] aClass];

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('P%d').outerHTML = '<span class=propsStyle><br><br>", pathID];

    unsigned pc;
    objc_property_t *props = class_copyPropertyList(aClass, &pc);
    for ( unsigned i=0 ; i<pc ; i++ ) {
        const char *attrs = property_getAttributes(props[i]);
        const char *name = property_getName(props[i]);

        [html appendFormat:@"@property () %@ <span onclick=\\'this.id =\"P%d\"; "
             "prompt( \"property:\", \"%d,%s\" ); event.cancelBubble = true;\\'>%s</span>; // %s<br>",
             [self xtype:attrs+1], pathID, pathID, name, name, attrs];
    }

    free( props );

    [html appendString:@"</span>';"];
    [self writeString:html];
}

+ (void)methods:(NSString *)input {
    int pathID = [input intValue];
    Class aClass = [paths[pathID] aClass];

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('M%d').outerHTML = '<br><span class=methodStyle>"
         "Method Filter: <input type=textfield size=10 onchange=\\'methodFilter(this);\\'>", pathID];

    Class stopClass = aClass == [NSObject class] ? Nil : [NSObject class];
    for ( Class bClass = aClass ; bClass && bClass != stopClass ; bClass = [bClass superclass] )
    [self dumpMethodType:"+" forClass:object_getClass(bClass) original:aClass pathID:pathID into:html];

    for ( Class bClass = aClass ; bClass && bClass != stopClass ; bClass = [bClass superclass] )
    [self dumpMethodType:"-" forClass:bClass original:aClass pathID:pathID into:html];

    [html appendString:@"</span>';"];
    [self writeString:html];
}

+ (void)dumpMethodType:(const char *)mtype forClass:(Class)aClass original:(Class)original
                pathID:(int)pathID into:(NSMutableString *)html {
    unsigned mc;
    Method *methods = class_copyMethodList(aClass, &mc);
    NSString *hide = aClass == original ? @"" :
    [NSString stringWithFormat:@" style=\\'display:none;\\' title=\\'%s\\'", class_getName(aClass)];

    if ( mc && ![hide length] )
        [html appendString:@"<br>"];

    for ( unsigned i=0 ; i<mc ; i++ ) {
        const char *name = sel_getName(method_getName(methods[i]));
        const char *type = method_getTypeEncoding(methods[i]);
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:type];
        NSArray *bits = [[NSString stringWithUTF8String:name] componentsSeparatedByString:@":"];

        [html appendFormat:@"<div sel=\\'%s\\'%@>%s (%@)", name, hide, mtype, [self xtype:[sig methodReturnType]]];

        if ( [sig numberOfArguments] > 2 )
            for ( int a=2 ; a<[sig numberOfArguments] ; a++ )
                [html appendFormat:@"%@:(%@)a%d ", bits[a-2], [self xtype:[sig getArgumentTypeAtIndex:a]], a-2];
        else
            [html appendFormat:@"<span onclick=\\'this.id =\"M%d\"; prompt( \"method:\", \"%d,%s\" );"
                "event.cancelBubble = true;\\'>%s</span> ", pathID, pathID, name, name];

        [html appendFormat:@";</div>"];
    }

    free( methods );
}

+ (void)protocol:(NSString *)protoName {
    Protocol *protocol = NSProtocolFromString(protoName);
    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('%@').outerHTML = '<span id=\\'%@\\' "
         "onclick=\\'if ( event.srcElement.tagName != \"INPUT\" ) { prompt( \"_protocol:\", \"%@\"); "
         "event.cancelBubble = true; }\\'><a href=\\'#\\' onclick=\\'prompt( \"_protocol:\", \"%@\"); "
         "event.cancelBubble = true; return false;\\'>%@</a><p><table><tr><td><td class=indent><td>"
         "<span class=protoStyle>@protocol %@", protoName, protoName, protoName, protoName, protoName, protoName];

    unsigned pc;
    Protocol *__unsafe_unretained *protos = protocol_copyProtocolList(protocol, &pc);
    if ( pc ) {
        [html appendString:@" &lt;"];

        for ( unsigned i=0 ; i<pc ; i++ ) {
            if ( i )
            [html appendString:@", "];
            NSString *protocolName = NSStringFromProtocol(protos[i]);
            [html appendString:[self xlinkForProtocol:protocolName]];
        }

        [html appendString:@"&gt;"];
        free( protos );
    }

    [html appendString:@"<br>"];

    objc_property_t *props = protocol_copyPropertyList(protocol, &pc);

    for ( unsigned i=0 ; i<pc ; i++ ) {
        const char *attrs = property_getAttributes(props[i]);
        const char *name = property_getName(props[i]);
        [html appendFormat:@"@property () %@ %s; // %s<br>", [self xtype:attrs+1], name, attrs];
    }

    free( props );

    [self dumpMethodsForProtocol:protocol required:YES instance:NO into:html];
    [self dumpMethodsForProtocol:protocol required:NO instance:NO into:html];

    [self dumpMethodsForProtocol:protocol required:YES instance:YES into:html];
    [self dumpMethodsForProtocol:protocol required:NO instance:YES into:html];

    [html appendString:@"<br>@end<p></span></table></span>';"];
    [self writeString:html];
}

// Thanks to http://bou.io/ExtendedTypeInfoInObjC.html !
extern "C" const char *_protocol_getMethodTypeEncoding(Protocol *,SEL,BOOL,BOOL);

+ (void)dumpMethodsForProtocol:(Protocol *)protocol required:(BOOL)required instance:(BOOL)instance into:(NSMutableString *)html {
    unsigned mc;
    objc_method_description *methods = protocol_copyMethodDescriptionList( protocol, required, instance, &mc );
    if ( mc )
        [html appendFormat:@"<br>@%@<br>", required ? @"required" : @"optional"];

    for ( unsigned i=0 ; i<mc ; i++ ) {
        const char *name = sel_getName(methods[i].name);
        const char *type;// = methods[i].types;

        type = _protocol_getMethodTypeEncoding(protocol, methods[i].name, required,instance);
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:type];
        NSArray *parts = [[NSString stringWithUTF8String:name] componentsSeparatedByString:@":"];

        [html appendFormat:@"%s (%@)", instance ? "-" : "+", [self xtype:[sig methodReturnType]]];
        if ( [sig numberOfArguments] > 2 )
            for ( int a=2 ; a<[sig numberOfArguments] ; a++ )
                [html appendFormat:@"%@:(%@)a%d ", parts[a-2], [self xtype:[sig getArgumentTypeAtIndex:a]], a-2];
        else
            [html appendFormat:@"%s", name];

        [html appendFormat:@" ;<br>"];
    }

    free( methods );
}

+ (void)_protocol:(NSString *)protocolName {
    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('%@').outerHTML = '%@';",
         protocolName, [html xlinkForProtocol:protocolName]];
    [self writeString:html];
}

+ (void)views:(NSString *)input {
    int pathID = [input intValue];
    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('V%d').outerHTML = '<br>", pathID];
    [self subviewswithPathID:pathID indent:0 into:html];

    [html appendString:@"';"];
    [self writeString:html];
}

+ (void)subviewswithPathID:(int)pathID indent:(int)indent into:(NSMutableString *)html {
    id obj = [paths[pathID] object];
    for ( int i=0 ; i<indent ; i++ )
        [html appendString:@"&nbsp; &nbsp; "];

    [obj xlinkForCommand:@"open" withPathID:pathID into:html];
    [html appendString:@"<br>"];

    NSArray *subviews = [obj subviews];
    for ( int i=0 ; i<[subviews count] ; i++ ) {
        XprobeView *path = [XprobeView withPathID:pathID];
        path.sub = i;
        [self subviewswithPathID:[path xadd] indent:indent+1 into:html];
    }
}

+ (void)trace:(NSString *)input {
    int pathID = [input intValue];
    id obj = [paths[pathID] object];
    Class aClass = [paths[pathID] aClass];

    [Xtrace setDelegate:self];
    [Xtrace traceInstance:obj class:aClass];
    [self writeString:[NSString stringWithFormat:@"Tracing <%s %p>", class_getName(aClass), obj]];
}

+ (void)xtrace:(NSString *)trace forInstance:(void *)obj {
    if ( !graphAnimating )
        [self writeString:trace];
    else if ( !dotGraph )
        instancesLabeled[(__bridge __unsafe_unretained id)obj].lastMessageTime = [NSDate timeIntervalSinceReferenceDate];
}

+ (void)animate:(NSString *)input {
    BOOL wasAnimating = graphAnimating;
    if ( (graphAnimating = [input intValue]) ) {
        [Xtrace setDelegate:self];
        for ( const auto &graphing : instancesLabeled )
            [Xtrace traceInstance:graphing.first];
        if ( !wasAnimating )
            [self performSelectorInBackground:@selector(sendUpdates) withObject:nil];
        NSLog( @"Xprobe: traced %d objects", (int)instancesLabeled.size() );
    }
    else
        for ( const auto &graphing : instancesLabeled )
            [Xtrace notrace:graphing.first];
}

+ (void)sendUpdates {
    while ( graphAnimating ) {
        NSTimeInterval then = [NSDate timeIntervalSinceReferenceDate];
        [NSThread sleepForTimeInterval:.5];

        if ( !dotGraph ) {
            NSMutableString *updates = [NSMutableString new];

            for ( auto &graphed : instancesLabeled )
                if ( graphed.second.lastMessageTime > then ) {
                    [updates appendFormat:@" $('%u').style.color = 'red';", graphed.second.sequence];
                    graphed.second.highlighted = TRUE;
                }
                else if ( graphed.second.highlighted ) {
                    [updates appendFormat:@" $('%u').style.color = 'black';", graphed.second.sequence];
                    graphed.second.highlighted = FALSE;
                }

            if ( [updates length] )
                [self writeString:[@"updates:" stringByAppendingString:updates]];
        }
    }
}

struct _xinfo { int pathID; id obj; Class aClass; NSString *name, *value; };

+ (struct _xinfo)parseInput:(NSString *)input {
    NSArray *parts = [input componentsSeparatedByString:@","];
    struct _xinfo info;

    info.pathID = [parts[0] intValue];
    info.obj = [paths[info.pathID] object];
    info.aClass = [paths[info.pathID] aClass];
    info.name = parts[1];

    if ( [parts count] >= 3 )
    info.value = parts[2];

    return info;
}

+ (void)ivar:(NSString *)input {
    struct _xinfo info = [self parseInput:input];
    Ivar ivar = class_getInstanceVariable(info.aClass, [info.name UTF8String]);

    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('I%d').outerHTML = '", info.pathID];
    [info.obj xspanForPathID:info.pathID ivar:ivar into:html];

    [html appendString:@"';"];
    [self writeString:html];
}

+ (void)edit:(NSString *)input {
    struct _xinfo info = [self parseInput:input];
    Ivar ivar = class_getInstanceVariable(info.aClass, [info.name UTF8String]);

    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('E%d').outerHTML = '"
         "<span id=E%d><input type=textfield size=10 value=\\'%@\\' "
         "onchange=\\'prompt(\"save:\", \"%d,%@,\"+this.value );\\'></span>';",
         info.pathID, info.pathID, [info.obj xvalueForIvar:ivar], info.pathID, info.name];

    [self writeString:html];
}

+ (void)save:(NSString *)input {
    struct _xinfo info = [self parseInput:input];
    Ivar ivar = class_getInstanceVariable(info.aClass, [info.name UTF8String]);

    if ( !ivar )
        NSLog( @"Xprobe: could not find ivar \"%@\" in %@", info.name, info.obj);
    else
        if ( ![info.obj xvalueForIvar:ivar update:info.value] )
            NSLog( @"Xprobe: unable to update ivar \"%@\" in %@", info.name, info.obj);

    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('E%d').outerHTML = '<span onclick=\\'"
         "this.id =\"E%d\"; prompt( \"edit:\", \"%d,%@\" ); event.cancelBubble = true;\\'><i>%@</i></span>';",
         info.pathID, info.pathID, info.pathID, info.name, [info.obj xvalueForIvar:ivar]];

    [self writeString:html];
}

+ (void)property:(NSString *)input {
    struct _xinfo info = [self parseInput:input];

    objc_property_t prop = class_getProperty(info.aClass, [info.name UTF8String]);
    char *getter = property_copyAttributeValue(prop, "G");

    SEL sel = sel_registerName( getter ? getter : [info.name UTF8String] );
    if ( getter ) free( getter );

    Method method = class_getInstanceMethod(info.aClass, sel);
    [self methodLinkFor:info method:method prefix:"P" command:"property:"];
}

+ (void)method:(NSString *)input {
    struct _xinfo info = [self parseInput:input];
    Method method = class_getInstanceMethod(info.aClass, NSSelectorFromString(info.name));
    [self methodLinkFor:info method:method prefix:"M" command:"method:"];
}

+ (void)methodLinkFor:(struct _xinfo &)info method:(Method)method
               prefix:(const char *)prefix command:(const char *)command {
    id result = method ? [info.obj xvalueForMethod:method] : @"nomethod";

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('%s%d').outerHTML = '<span onclick=\\'"
         "this.id =\"%s%d\"; prompt( \"%s\", \"%d,%@\" ); event.cancelBubble = true;\\'>%@ = ",
         prefix, info.pathID, prefix, info.pathID, command, info.pathID, info.name, info.name];

    if ( result && method && method_getTypeEncoding(method)[0] == '@' ) {
        XprobeMethod *subpath = [XprobeMethod withPathID:info.pathID];
        subpath.name = method_getName(method);
        [result xlinkForCommand:@"open" withPathID:[subpath xadd] into:html];
    }
    else
        [html appendFormat:@"%@", result ? result : @"nil"];

    [html appendString:@"</span>';"];
    [self writeString:html];
}

+ (void)siblings:(NSString *)input {
    int pathID = [input intValue];
    Class aClass = [paths[pathID] aClass];

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('S%d').outerHTML = '<p>", pathID];

    for ( const auto &obj : instancesByClass[aClass] ) {
        XprobeRetained *path = [XprobeRetained new];
        path.object = obj;
        [obj xlinkForCommand:@"open" withPathID:[path xadd] into:html];
        [html appendString:@" "];
    }

    [html appendString:@"<p>';"];
    [self writeString:html];
}

+ (void)render:(NSString *)input {
    int pathID = [input intValue];
    __block NSData *data = nil;

    dispatch_sync(dispatch_get_main_queue(), ^{
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
        UIView *view = [paths[pathID] object];
        if ( ![view respondsToSelector:@selector(layer)] )
        return;

        UIGraphicsBeginImageContext(view.frame.size);
        [view.layer renderInContext:UIGraphicsGetCurrentContext()];
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        data = UIImagePNGRepresentation(image);
        UIGraphicsEndImageContext();
#else
        NSView *view = [paths[pathID] object];
        NSSize imageSize = view.bounds.size;
        if ( !imageSize.width || !imageSize.height )
        return;

        NSBitmapImageRep *bir = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:bir];
        data = [bir representationUsingType:NSPNGFileType properties:nil];
#endif
    });

    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('R%d').outerHTML = '<span id=\\'R%d\\'><p>"
         "<img src=\\'data:image/png;base64,%@\\' onclick=\\'prompt(\"_render:\", \"%d\"); "
         "event.cancelBubble = true;\\'><p></span>';", pathID, pathID,
         [data base64EncodedStringWithOptions:0], pathID];
    [self writeString:html];
}

+ (void)_render:(NSString *)input {
    int pathID = [input intValue];
    NSMutableString *html = [NSMutableString new];
    [html appendFormat:@"$('R%d').outerHTML = '", pathID];
    [html xlinkForCommand:@"render" withPathID:pathID into:html];
    [html appendString:@"';"];
    [self writeString:html];
}

+ (void)class:(NSString *)className {
    XprobeClass *path = [XprobeClass new];
    if ( !(path.aClass = NSClassFromString(className)) )
        return;

    int pathID = [path xadd];
    NSMutableString *html = [NSMutableString new];

    [html appendFormat:@"$('%@').outerHTML = '", className];
    [path xlinkForCommand:@"close" withPathID:pathID into:html];

    [html appendString:@"<br><table><tr><td class=indent><td class=drilldown>"];
    [path xopenWithPathID:pathID into:html];
    
    [html appendString:@"</table></span>';"];
    [self writeString:html];
}

@end

@implementation NSObject(Xprobe)

/*****************************************************
 ********* sweep and object display methods **********
 *****************************************************/

- (void)xsweep {
    BOOL sweptAlready = instancesSeen.find(self) != instancesSeen.end();
    __unsafe_unretained id from = sweepState.from;
    const char *source = sweepState.source;

    if ( !sweptAlready )
        instancesSeen[self] = sweepState;

    BOOL didConnect = [from xgraphConnectionTo:self];

    if ( sweptAlready )
        return;

    XprobeRetained *path = retainObjects ? [XprobeRetained new] : (XprobeRetained *)[XprobeAssigned new];
    path.object = self;

    assert( [path xadd] == sweepState.sequence );

    sweepState.from = self;
    sweepState.sequence++;
    sweepState.depth++;

    const char *className = class_getName([self class]);
    BOOL legacy = [Xprobe xprobeExclude:className];

    if ( logXprobeSweep )
        printf( "Xprobe sweep %d: <%s %p>\n", sweepState.depth, className, self);

    for ( Class aClass = [self class] ; aClass && aClass != [NSObject class] ; aClass = [aClass superclass] ) {
        if ( className[1] != '_' )
            instancesByClass[aClass].push_back(self);

        // avoid scanning legacy classes
        if ( legacy )
            continue;

        unsigned ic;
        Ivar *ivars = class_copyIvarList(aClass, &ic);
        for ( unsigned i=0 ; i<ic ; i++ )
            if ( ivar_getTypeEncoding(ivars[i])[0] == '@' ) {
                sweepState.source = ivar_getName(ivars[i]);
                [[self xvalueForIvar:ivars[i]] xsweep];
            }

        free( ivars );
    }

    sweepState.source = "target";
    if ( [self respondsToSelector:@selector(target)] ) {
        if ( [self respondsToSelector:@selector(action)] )
            sweepState.source = sel_getName([self action]);
        [[self target] xsweep];
    }
    sweepState.source = "delegate";
    if ( [self respondsToSelector:@selector(delegate)] )
        [[self delegate] xsweep];
    sweepState.source = "document";
    if ( [self respondsToSelector:@selector(document)] )
        [[self document] xsweep];

    sweepState.source = "contentView";
    if ( [self respondsToSelector:@selector(contentView)] )
        [[self contentView] xsweep];

    sweepState.source = "subview";
    if ( [self respondsToSelector:@selector(subviews)] )
        [[self subviews] xsweep];

    sweepState.source = "subscene";
    if ( [self respondsToSelector:@selector(getNSArray)] )
        [[self getNSArray] xsweep];

    sweepState.source = source;
    sweepState.from = from;
    sweepState.depth--;

    if ( !didConnect && graphOptions & XGraphInterconnections )
        [from xgraphConnectionTo:self];
}

- (void)xopenWithPathID:(int)pathID into:(NSMutableString *)html
{
    XprobePath *path = paths[pathID];
    Class aClass = [path aClass];

    NSString *closer = [NSString stringWithFormat:@"<span onclick=\\'prompt(\"close:\",\"%d\"); "
                        "event.cancelBubble = true;\\'>%s</span>", pathID, class_getName(aClass)];
    [html appendFormat:[self class] == aClass ? @"<b>%@</b>" : @"%@", closer];

    if ( [aClass superclass] ) {
        XprobeSuper *superPath = [path class] == [XprobeClass class] ? [XprobeClass new] :
            [XprobeSuper withPathID:[path class] == [XprobeSuper class] ? path.pathID : pathID];
        superPath.aClass = [aClass superclass];
        
        [html appendString:@" : "];
        [self xlinkForCommand:@"open" withPathID:[superPath xadd] into:html];
    }

    unsigned c;
    Protocol *__unsafe_unretained *protos = class_copyProtocolList(aClass, &c);
    if ( c ) {
        [html appendString:@" &lt;"];

        for ( unsigned i=0 ; i<c ; i++ ) {
            if ( i )
                [html appendString:@", "];
            NSString *protocolName = NSStringFromProtocol(protos[i]);
            [html appendString:[self xlinkForProtocol:protocolName]];
        }

        [html appendString:@"&gt;"];
        free( protos );
    }

    [html appendString:@" {<br>"];

    Ivar *ivars = class_copyIvarList(aClass, &c);
    for ( unsigned i=0 ; i<c ; i++ ) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        [html appendFormat:@" &nbsp; &nbsp;%@ ", [self xtype:type]];
        [self xspanForPathID:pathID ivar:ivars[i] into:html];
        [html appendString:@";<br>"];
    }

    free( ivars );

    [html appendFormat:@"} "];
    [self xlinkForCommand:@"properties" withPathID:pathID into:html];
    [html appendFormat:@" "];
    [self xlinkForCommand:@"methods" withPathID:pathID into:html];
    [html appendFormat:@" "];
    [self xlinkForCommand:@"siblings" withPathID:pathID into:html];

    if ( [path class] != [XprobeClass class] ) {
        [html appendFormat:@" "];
        [self xlinkForCommand:@"trace" withPathID:pathID into:html];

        if ( [self respondsToSelector:@selector(subviews)] ) {
            [html appendFormat:@" "];
            [self xlinkForCommand:@"render" withPathID:pathID into:html];
            [html appendFormat:@" "];
            [self xlinkForCommand:@"views" withPathID:pathID into:html];
        }
    }

    [html appendFormat:@" "];
    [html appendFormat:@" <a href=\\'#\\' onclick=\\'prompt(\"close:\",\"%d\"); return false;\\'>close</a>", pathID];
}

- (void)xspanForPathID:(int)pathID ivar:(Ivar)ivar into:(NSMutableString *)html {
    const char *type = ivar_getTypeEncoding(ivar);
    const char *name = ivar_getName(ivar);

    [html appendFormat:@"<span onclick=\\'if ( event.srcElement.tagName != \"INPUT\" ) { this.id =\"I%d\"; "
        "prompt( \"ivar:\", \"%d,%s\" ); event.cancelBubble = true; }\\'>%s", pathID, pathID, name, name];

    if ( [paths[pathID] class] != [XprobeClass class] ) {
        [html appendString:@" = "];
        if ( type[0] != '@' )
            [html appendFormat:@"<span onclick=\\'this.id =\"E%d\"; prompt( \"edit:\", \"%d,%s\" ); "
                "event.cancelBubble = true;\\'>%@</span>", pathID, pathID, name,
                [[self xvalueForIvar:ivar] xhtmlEscape]];
        else {
            id subObject = [self xvalueForIvar:ivar];
            if ( subObject ) {
                XprobeIvar *ivarPath = [XprobeIvar withPathID:pathID];
                ivarPath.name = ivar_getName(ivar);
                [subObject xlinkForCommand:@"open" withPathID:[ivarPath xadd] title:ivarPath.name into:html];
            }
            else
                [html appendString:@"nil"];
        }
    }

    [html appendString:@"</span>"];
}

- (void)xlinkForCommand:(NSString *)which withPathID:(int)pathID into:html {
    [self xlinkForCommand:which withPathID:pathID title:NULL into:html];
}

- (void)xlinkForCommand:(NSString *)which withPathID:(int)pathID title:(const char *)title into:html
{
    if ( self == trapped ) {
        [html appendString:trapped];
        return;
    }

    Class linkClass = [paths[pathID] aClass];
    unichar firstChar = toupper([which characterAtIndex:0]);

    BOOL basic = [which isEqualToString:@"open"] || [which isEqualToString:@"close"];
    NSString *label = !basic ? which : [self class] != linkClass ? NSStringFromClass(linkClass) :
        [NSString stringWithFormat:@"&lt;%s&nbsp;%p&gt;", class_getName([self class]), self];

    [html appendFormat:@"<span id=\\'%@%d\\'><a href=\\'#\\' onclick=\\'prompt( \"%@:\", \"%d\" ); "
        "event.cancelBubble = true; return false;\\'%@>%@</a>%@",
        basic ? @"" : [NSString stringWithCharacters:&firstChar length:1],
        pathID, which, pathID, title ? [NSString stringWithFormat:@" title=\\'%s\\'", title] : @"",
        label, [which isEqualToString:@"close"] ? @"" : @"</span>"];
}

/*****************************************************
 ********* dot object graph generation code **********
 *****************************************************/

- (BOOL)xgraphInclude {
    NSString *className = NSStringFromClass([self class]);
    return [className characterAtIndex:0] != '_' && ![className hasPrefix:@"NS"] &&
        ![className hasPrefix:@"UI"] && ![className hasPrefix:@"CA"] &&
        ![className hasPrefix:@"WAK"] && ![className hasPrefix:@"Web"];
}

- (BOOL)xgraphExclude {
    NSString *className = NSStringFromClass([self class]);
    return [className characterAtIndex:0] == '_' || [className isEqual:@"CALayer"] || [className hasPrefix:@"NSIS"] ||
        [className hasSuffix:@"Constraint"] || [className hasSuffix:@"Variable"] || [className hasSuffix:@"Color"];
}

- (void)xgraphLabelNode {
    NSString *className = NSStringFromClass([self class]);
    if ( instancesLabeled.find(self) == instancesLabeled.end() ) {
        instancesLabeled[self].sequence = instancesSeen[self].sequence;
        [dotGraph appendFormat:@"    %d [label=\"%@\" tooltip=\"<%@ %p> #%d\"%s%s];\n",
             instancesSeen[self].sequence, className, className, self, instancesSeen[self].sequence,
             [self respondsToSelector:@selector(subviews)] ? " shape=box" : "",
             [self xgraphInclude] ? " style=filled" : ""];
    }
}

- (BOOL)xgraphConnectionTo:(id)ivar {
    if ( dotGraph && ivar != (id)kCFNull &&
            (graphOptions & XGraphArrayWithoutLmit || currentMaxArrayIndex < maxArrayItemsForGraphing) &&
            (graphOptions & XGraphAllObjects || [self xgraphInclude] || [ivar xgraphInclude] ||
                (graphOptions & XGraphInterconnections &&
                 instancesLabeled.find(self) != instancesLabeled.end() &&
                 instancesLabeled.find(ivar) != instancesLabeled.end())) &&
            (graphOptions & XGraphWithoutExcepton || (![self xgraphExclude] && ![ivar xgraphExclude])) ) {
        [self xgraphLabelNode];
        [ivar xgraphLabelNode];
        [dotGraph appendFormat:@"    %d -> %d [label=\"%s\"];\n",
             instancesSeen[self].sequence, instancesSeen[ivar].sequence, sweepState.source];
        return YES;
    }
    else
        return NO;
}

/*****************************************************
 ********* generic ivar/method/type access ***********
 *****************************************************/

- (id)xvalueForIvar:(Ivar)ivar {
    const char *iptr = (char *)(__bridge void *)self + ivar_getOffset(ivar);
    return [self xvalueForPointer:iptr type:ivar_getTypeEncoding(ivar)];
}

- (id)xvalueForMethod:(Method)method {
    const char *type = method_getTypeEncoding(method);
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:type];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
    [invocation setSelector:method_getName(method)];
    [invocation invokeWithTarget:self];

    NSUInteger size = 0, align;
    const char *returnType = [sig methodReturnType];
    NSGetSizeAndAlignment(returnType, &size, &align);

    char buffer[size];
    if ( type[0] != 'v' )
        [invocation getReturnValue:buffer];
    return [self xvalueForPointer:buffer type:returnType];
}

#ifndef __IPHONE_OS_VERSION_MIN_REQUIRED
static jmp_buf jmp_env;

static void handler( int sig ) {
	longjmp( jmp_env, sig );
}
#endif

static NSString *trapped = @"#INVALID";

- (id)xvalueForPointer:(const char *)iptr type:(const char *)type {
    switch ( type[0] ) {
        case 'V':
        case 'v': return @"void";
        case 'B': return @(*(bool *)iptr);
        case 'c': return @(*(char *)iptr);
        case 'C': return @(*(unsigned char *)iptr);
        case 's': return @(*(short *)iptr);
        case 'S': return @(*(unsigned short *)iptr);
        case 'i': return @(*(int *)iptr);
        case 'I': return @(*(unsigned *)iptr);

        case 'f': return @(*(float *)iptr);
        case 'd': return @(*(double *)iptr);

#ifndef __LP64__
        case 'q': return @(*(long long *)iptr);
#else
        case 'q':
#endif
        case 'l': return @(*(long *)iptr);
#ifndef __LP64__
        case 'Q': return @(*(unsigned long long *)iptr);
#else
        case 'Q':
#endif
        case 'L': return @(*(unsigned long *)iptr);

        case '@': {
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
            return *((const id *)(void *)iptr);
#else
            void (*savetrap)(int) = signal( SIGTRAP, handler );
            void (*savesegv)(int) = signal( SIGSEGV, handler );
            void (*savebus )(int) = signal( SIGBUS,  handler );

            id out = trapped;
            int signo;

            switch ( signo = setjmp( jmp_env ) ) {
                case 0:
                    [*((const id *)(void *)iptr) description];
                    out = *((const id *)(void *)iptr);
                    break;
                default:
                    [Xprobe writeString:[NSString stringWithFormat:@"SIGNAL: %d", signo]];
            }

            signal( SIGBUS,  savebus  );
            signal( SIGSEGV, savesegv );
            signal( SIGTRAP, savetrap );
            return out;
#endif
        }
        case ':': return NSStringFromSelector(*(SEL *)iptr);
        case '#': {
            Class aClass = *(const Class *)(void *)iptr;
            return aClass ? [NSString stringWithFormat:@"[%@ class]", aClass] : @"Nil";
        }
        case '^': return [NSValue valueWithPointer:*(void **)iptr];

        case '{': try {
            // remove names for valueWithBytes:objCType:
            char type2[strlen(type)+1], *tptr = type2;
            while ( *type )
                if ( *type == '"' ) {
                    while ( *++type != '"' )
                        ;
                    type++;
                }
                else
                    *tptr++ = *type++;
            *tptr = '\000';
            return [NSValue valueWithBytes:iptr objCType:type2];
        }
            catch ( NSException *e ) {
                return @"raised exception";
            }
        case '*': {
            const char *ptr = *(const char **)iptr;
            return ptr ? [NSString stringWithUTF8String:ptr] : @"NULL";
        }
        case 'b':
            return [NSString stringWithFormat:@"0x%08x", *(int *)iptr];
        default:
            return @"unknown type";
    }
}

- (BOOL)xvalueForIvar:(Ivar)ivar update:(NSString *)value {
    const char *iptr = (char *)(__bridge void *)self + ivar_getOffset(ivar);
    const char *type = ivar_getTypeEncoding(ivar);
    switch ( type[0] ) {
        case 'B': *(bool *)iptr = [value intValue]; break;
        case 'c': *(char *)iptr = [value intValue]; break;
        case 'C': *(unsigned char *)iptr = [value intValue]; break;
        case 's': *(short *)iptr = [value intValue]; break;
        case 'S': *(unsigned short *)iptr = [value intValue]; break;
        case 'i': *(int *)iptr = [value intValue]; break;
        case 'I': *(unsigned *)iptr = [value intValue]; break;
        case 'f': *(float *)iptr = [value floatValue]; break;
        case 'd': *(double *)iptr = [value doubleValue]; break;
#ifndef __LP64__
        case 'q': *(long long *)iptr = [value longLongValue]; break;
#else
        case 'q':
#endif
        case 'l': *(long *)iptr = (long)[value longLongValue]; break;
#ifndef __LP64__
        case 'Q': *(unsigned long long *)iptr = [value longLongValue]; break;
#else
        case 'Q':
#endif
        case 'L': *(unsigned long *)iptr = (unsigned long)[value longLongValue]; break;
        case ':': *(SEL *)iptr = NSSelectorFromString(value); break;
        default:
            NSLog( @"Xprobe: update of unknown type: %s", type );
            return FALSE;
    }

    return TRUE;
}

- (NSString *)xtype:(const char *)type {
    NSString *typeStr = [self _xtype:type];
    return [NSString stringWithFormat:@"<span class=%@>%@</span>",
            [typeStr hasSuffix:@"*"] ? @"classStyle" : @"typeStyle", typeStr];
}

- (NSString *)_xtype:(const char *)type {
    switch ( type[0] ) {
        case 'V': return @"oneway void";
        case 'v': return @"void";
        case 'B': return @"bool";
        case 'c': return @"char";
        case 'C': return @"unsigned char";
        case 's': return @"short";
        case 'S': return @"unsigned short";
        case 'i': return @"int";
        case 'I': return @"unsigned";
        case 'f': return @"float";
        case 'd': return @"double";
#ifndef __LP64__
        case 'q': return @"long long";
#else
        case 'q':
#endif
        case 'l': return @"long";
#ifndef __LP64__
        case 'Q': return @"unsigned long long";
#else
        case 'Q':
#endif
        case 'L': return @"unsigned long";
        case ':': return @"SEL";
        case '#': return @"Class";
        case '@': return [self xtype:type+1 star:" *"];
        case '^': return [self xtype:type+1 star:" *"];
        case '{': return [self xtype:type star:""];
        case 'r':
            return [@"const " stringByAppendingString:[self xtype:type+1]];
        case '*': return @"char *";
        default:
            return [NSString stringWithUTF8String:type]; //@"id";
    }
}

- (NSString *)xtype:(const char *)type star:(const char *)star {
    if ( type[-1] == '@' ) {
        if ( type[0] != '"' )
            return @"id";
        else if ( type[1] == '<' )
            type++;
    }
    if ( type[-1] == '^' && type[0] != '{' )
        return [[self xtype:type] stringByAppendingString:@" *"];

    const char *end = ++type;
    while ( isalpha(*end) || *end == '_' || *end == ',' )
        end++;
    if ( type[-1] == '<' )
        return [NSString stringWithFormat:@"id&lt;%@&gt;",
                    [self xlinkForProtocol:[NSString stringWithFormat:@"%.*s", (int)(end-type), type]]];
    else {
        NSString *className = [NSString stringWithFormat:@"%.*s", (int)(end-type), type];
        return [NSString stringWithFormat:@"<span onclick=\\'this.id=\"%@\"; "
                    "prompt( \"class:\", \"%@\" ); event.cancelBubble=true;\\'>%@</span>%s",
                    className, className, className, star];
    }
}

- (NSString *)xlinkForProtocol:(NSString *)protocolName {
    return [NSString stringWithFormat:@"<a href=\\'#\\' onclick=\\'this.id=\"%@\"; prompt( \"protocol:\", \"%@\" ); "
                "event.cancelBubble = true; return false;\\'>%@</a>", protocolName, protocolName, protocolName];
}

- (NSString *)xhtmlEscape {
    return [[[[[[self description]
                stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
               stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"]
              stringByReplacingOccurrencesOfString:@"\n" withString:@"<br>"]
             stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
            stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
}

@end

/*****************************************************
 ************ sweep of foundation classes ************
 *****************************************************/

@implementation NSSet(Xprobe)

- (void)xsweep {
    [[self allObjects] xsweep];
}

- (void)xopenWithPathID:(int)pathID into:(NSMutableString *)html
{
    [html appendString:@"["];
    for ( int i=0 ; i<[self count] ; i++ ) {
        if ( i )
            [html appendString:@", "];

        XprobeSet *path = [XprobeSet withPathID:pathID];
        path.sub = i;
        [[self allObjects][i] xlinkForCommand:@"open" withPathID:[path xadd] into:html];
    }
    [html appendString:@"]"];
}

@end

@implementation NSArray(Xprobe)

- (void)xsweep {
    sweepState.depth++;
    unsigned saveMaxArrayIndex = currentMaxArrayIndex;

    for ( unsigned i=0 ; i<[self count] ; i++ ) {
        if ( currentMaxArrayIndex < i )
            currentMaxArrayIndex = i;
        [self[i] xsweep];
    }

    currentMaxArrayIndex = saveMaxArrayIndex;
    sweepState.depth--;
}

- (void)xopenWithPathID:(int)pathID into:(NSMutableString *)html
{
    [html appendString:@"("];

    for ( int i=0 ; i<[self count] ; i++ ) {
        if ( i )
            [html appendString:@", "];

        XprobeArray *path = [XprobeArray withPathID:pathID];
        path.sub = i;
        [self[i] xlinkForCommand:@"open" withPathID:[path xadd] into:html];
    }

    [html appendString:@")"];
}

@end

@implementation NSDictionary(Xprobe)

- (void)xsweep {
    [[self allValues] xsweep];
}

- (void)xopenWithPathID:(int)pathID into:(NSMutableString *)html
{
    [html appendString:@"{<br>"];

    for ( id key : [self allKeys] ) {
        [html appendFormat:@" &nbsp; &nbsp;%@ => ", key];

        XprobeDict *path = [XprobeDict withPathID:pathID];
        path.sub = key;

        [self[key] xlinkForCommand:@"open" withPathID:[path xadd] into:html];
        [html appendString:@",<br>"];
    }

    [html appendString:@"}"];
}

@end

@implementation NSString(Xprobe)

- (void)xsweep {
}

- (void)xopenWithPathID:(int)pathID into:(NSMutableString *)html
{
    [html appendFormat:@"@\"%@\"", [self xhtmlEscape]];
}

@end

@implementation NSValue(Xprobe)

- (void)xsweep {
}

- (void)xopenWithPathID:(int)pathID into:(NSMutableString *)html
{
    [html appendString:[self xhtmlEscape]];
}

@end

@implementation NSData(Xprobe)

- (void)xsweep {
}

- (void)xopenWithPathID:(int)pathID into:(NSMutableString *)html
{
    [html appendString:[self xhtmlEscape]];
}

@end

