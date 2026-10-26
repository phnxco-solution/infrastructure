<?php

/**
 * Proves how a Laravel app behaves behind Traefik, without needing Traefik.
 *
 * A request arrives as visitor -> Cloudflare -> Traefik -> nginx -> php-fpm, over plain http.
 * Traefik keeps the X-Forwarded-For Cloudflare sent and appends Cloudflare's edge address,
 * so PHP sees REMOTE_ADDR = Traefik and X-Forwarded-For = "<anything the visitor typed>,
 * <visitor>, <Cloudflare edge>". Laravel has to trust Traefik and Cloudflare by address, and
 * only X-Forwarded-For and X-Forwarded-Proto. Get it wrong and nothing breaks locally or in
 * CI, only once deployed: signed links in emails 403, and IP rate limiters key every visitor
 * to Traefik, to a Cloudflare edge, or to whatever address the visitor chose to send.
 *
 * Run inside the app's production image:
 *
 *   docker run --rm -e APP_URL=https://<domain> \
 *     -v /abs/path/to/probe-proxy.php:/tmp/probe.php:ro \
 *     <image> php /tmp/probe.php
 *
 *   # optional: name a signed route instead of auto-discovering one
 *   ... php /tmp/probe.php <signed.route.name> <param>=<value>
 *
 * APP_URL must be https — signed URLs are generated from it, so an http APP_URL makes the
 * probe report a failure that isn't real. The script aborts rather than let that happen.
 * APP_KEY is not needed: signing and verification use the same key, whatever it is.
 *
 * Exit codes:
 *   0  PASS — proxy headers are trusted
 *   1  FAIL: the app's trusted proxies are wrong; see "Trusted proxies" in references/laravel.md
 *   2  ABORT — the probe could not run (bad APP_URL, unbootable app). NOT a verdict.
 */

use Illuminate\Contracts\Console\Kernel as ConsoleKernel;
use Illuminate\Contracts\Http\Kernel as HttpKernel;
use Illuminate\Http\Middleware\TrustProxies;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;
use Illuminate\Support\Facades\URL;

const SPOOFED     = '6.6.6.6';       // what a visitor can put in X-Forwarded-For
const REAL_CLIENT = '93.87.10.55';   // the customer
const EDGE_IP     = '162.158.1.1';   // the Cloudflare edge that Traefik appends
const PROXY_IP    = '172.18.0.4';    // the traefik container

function abort_probe(string $message): never
{
    fwrite(STDERR, 'ABORT: '.$message.PHP_EOL);
    exit(2);
}

if (! is_file('/var/www/html/vendor/autoload.php')) {
    abort_probe('no vendor/autoload.php at /var/www/html — is this the app\'s production image?');
}

require '/var/www/html/vendor/autoload.php';

try {
    $app = require '/var/www/html/bootstrap/app.php';
    // The console kernel's SetRequestForConsole bootstrapper is what points
    // URL::signedRoute at APP_URL.
    $app->make(ConsoleKernel::class)->bootstrap();
    // Resolving the HTTP kernel is what fires bootstrap/app.php's withMiddleware()
    // closure — that's where trustProxies(at:) writes its static. Laravel only re-runs
    // that closure for the console kernel from v12.52; without this line the probe
    // reports a false FAIL on every earlier version. Resolve only, don't bootstrap.
    $app->make(HttpKernel::class);
} catch (Throwable $e) {
    abort_probe('the app could not boot: '.$e->getMessage());
}

$appUrl = (string) config('app.url');
$parts = parse_url($appUrl) ?: [];

if (($parts['scheme'] ?? null) !== 'https' || ($parts['host'] ?? '') === '') {
    abort_probe('APP_URL must be an https:// URL with a host; got '.var_export($appUrl, true).'.'.PHP_EOL
        .'Signed URLs are generated from APP_URL, so anything else reports a false failure.'.PHP_EOL
        .'Re-run with:  -e APP_URL=https://<domain>');
}

$host = $parts['host'];

/**
 * The TrustProxies instance the app actually runs — not necessarily the framework's.
 * An app carrying a Laravel 10-era App\Http\Middleware\TrustProxies subclass trusts
 * proxies correctly, but `new TrustProxies` would read a static it never set and report
 * a false FAIL. Null means nothing trusts proxies, which is itself the answer.
 */
function trust_proxies_middleware(): ?TrustProxies
{
    foreach (app(HttpKernel::class)->getGlobalMiddleware() as $class) {
        if (is_string($class) && is_a($class, TrustProxies::class, true)) {
            return app($class);
        }
    }

    return null;
}

/** Build a request shaped exactly like Cloudflare -> Traefik -> nginx -> fpm delivers one. */
function forwarded(string $url, ?string $forwardedHost = null): Request
{
    $request = Request::create($url, 'GET');
    $request->server->set('REMOTE_ADDR', PROXY_IP);
    $request->headers->set('X-Forwarded-For', SPOOFED.', '.REAL_CLIENT.', '.EDGE_IP);
    $request->headers->set('X-Forwarded-Proto', 'https');
    $request->headers->set('X-Forwarded-Host', $forwardedHost ?? parse_url($url, PHP_URL_HOST));

    trust_proxies_middleware()?->handle($request, fn ($r) => null);

    return $request;
}

$results = [];

$request = forwarded("http://{$host}/");
$results[] = ['client IP surfaces', $request->ip() === REAL_CLIENT, $request->ip()];
$results[] = ['isSecure()', $request->isSecure() === true, var_export($request->isSecure(), true)];
$results[] = ['url() scheme', str_starts_with($request->url(), 'https://'), $request->url()];

// A visitor can send X-Forwarded-Host through Cloudflare; trusting it lets them pick the host
// every absolute URL in that request is built from.
$request = forwarded("http://{$host}/", 'evil.example');
$results[] = ['forwarded host ignored', $request->getHost() === $host, $request->getHost()];

// Signed URLs: the failure that kills emailed links. Generated from APP_URL (https, in a
// queued Mailable), verified against the inbound request's rebuilt URL.
$routeName = $argv[1] ?? null;
$params = [];

foreach (array_slice($argv, 2) as $arg) {
    [$k, $v] = array_pad(explode('=', $arg, 2), 2, null);
    $params[$k] = $v;
}

try {
    if ($routeName === null) {
        foreach (Route::getRoutes() as $route) {
            // Only absolute 'signed'. A 'signed:relative' route ignores scheme, so it
            // cannot demonstrate the bug — skipping it is correct, not a miss.
            if (in_array('signed', $route->gatherMiddleware(), true) && $route->getName()) {
                $routeName = $route->getName();
                $params = array_fill_keys($route->parameterNames(), 1);
                break;
            }
        }
    }

    if ($routeName === null) {
        $results[] = ['signed routes', null, 'none found — skipped'];
    } else {
        $signed = URL::signedRoute($routeName, $params);
        $inbound = forwarded(preg_replace('#^https://#', 'http://', $signed));
        $results[] = ["signed route '{$routeName}' validates", URL::hasValidSignature($inbound), $signed];
    }
} catch (Throwable $e) {
    $results[] = ["signed route '".($routeName ?? '?')."'", null, 'could not test: '.$e->getMessage()];
}

$failed = false;

foreach ($results as [$label, $ok, $detail]) {
    $tag = $ok === null ? 'SKIP' : ($ok ? 'PASS' : 'FAIL');
    $failed = $failed || $ok === false;
    printf('[%s] %-32s %s%s', $tag, $label, $detail, PHP_EOL);
}

if ($failed) {
    echo PHP_EOL, "FAILED: this app's trusted proxies are wrong.", PHP_EOL,
         'Visitor IPs, https URLs or signed links will be wrong behind Cloudflare and Traefik.', PHP_EOL,
         'Trust Traefik and Cloudflare by address, never with \'*\': see "Trusted proxies" in references/laravel.md.', PHP_EOL;
    exit(1);
}

echo PHP_EOL, 'OK: proxy headers are trusted.', PHP_EOL;
