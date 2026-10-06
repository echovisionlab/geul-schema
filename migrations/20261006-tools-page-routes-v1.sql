-- Forward-only upgrade. Apply before assigning CMS Pages to tool routes.
-- Generic tools descendants become available; the p5 runner stays app-owned.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

ALTER TABLE public.page DROP CONSTRAINT IF EXISTS chk_page_slug_route_namespace;
ALTER TABLE public.page ADD CONSTRAINT chk_page_slug_route_namespace CHECK (
    (slug IS NULL) OR (
        slug = btrim(slug)
        AND slug <> ''
        AND left(slug, 1) <> '/'
        AND right(slug, 1) <> '/'
        AND strpos(slug, '//') = 0
        AND NOT (string_to_array(slug, '/') && ARRAY['.', '..'])
        AND lower(split_part(slug, '/', 1)) <> ALL (ARRAY[
            '_next', 'account', 'admin', 'api', 'auth', 'category',
            'changelog', 'favicon.ico', 'files', 'login', 'manifest.webmanifest',
            'my', 'onboarding', 'privacy', 'robots.txt', 's', 'sitemap',
            'sitemap.xml', 'sitemaps', 'subscribe', 'tag', 'terms',
            'unsubscribe', 'user', 'verification', 'verify'
        ])
        AND lower(slug) !~ '^tools/p5-runner(/|$)'
    )
);

COMMIT;
