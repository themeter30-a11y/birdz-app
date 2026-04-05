import Foundation

enum BirdzMonitorInjectedScript {
    static let source = """
    (function() {
        var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.birdzNotificationMonitor;
        if (!handler) return 'birdz-handler-missing';

        var SAFE_STYLE_ID = 'birdz-safe-area-style';

        function trimText(value) {
            return (value || '').replace(/\s+/g, ' ').trim();
        }

        function normalizeUrl(value) {
            try {
                return new URL(value, window.location.href).toString();
            } catch (error) {
                return null;
            }
        }

        function upsertViewport() {
            if (!document.head) return;

            var viewport = document.querySelector('meta[name="viewport"]');
            var content = 'width=device-width, initial-scale=1.0, viewport-fit=cover';

            if (!viewport) {
                viewport = document.createElement('meta');
                viewport.name = 'viewport';
                document.head.appendChild(viewport);
            }

            if (viewport.getAttribute('content') !== content) {
                viewport.setAttribute('content', content);
            }
        }

        function ensureSafeArea() {
            upsertViewport();

            if (!document.head) return;

            var style = document.getElementById(SAFE_STYLE_ID);
            if (style) return;

            style = document.createElement('style');
            style.id = SAFE_STYLE_ID;
            style.textContent = `
                :root {
                    --birdz-safe-top: env(safe-area-inset-top, 0px);
                }

                body::before {
                    content: '';
                    display: block;
                    height: var(--birdz-safe-top);
                    width: 100%;
                    pointer-events: none;
                }

                header,
                .header,
                #header,
                .header-main,
                .header_top,
                .topbar,
                .navbar,
                .navigation {
                    padding-top: var(--birdz-safe-top) !important;
                    box-sizing: border-box !important;
                }
            `;

            document.head.appendChild(style);
        }

        function parseCount(text) {
            var match = trimText(text).match(/\d+/);
            return match ? parseInt(match[0], 10) : 0;
        }

        function detectType(text) {
            var value = trimText(text).toLowerCase();

            if (value.indexOf('tajn') > -1 || value.indexOf('správ') > -1 || value.indexOf('sprav') > -1 || value.indexOf('ts') > -1) {
                return 'Tajná správa';
            }

            if (value.indexOf('reakci') > -1) {
                return 'Reakcia na status';
            }

            if (value.indexOf('koment') > -1) {
                return 'Komentár';
            }

            if (value.indexOf('sleduj') > -1) {
                return 'Nový sledovateľ';
            }

            if (value.indexOf('označil') > -1 || value.indexOf('oznacil') > -1) {
                return 'Označenie';
            }

            return 'Upozornenie';
        }

        function badgeCandidates(root) {
            return root.querySelectorAll([
                '.button-more .badge',
                '.header_user_avatar .badge',
                '.header .badge',
                '.badge',
                '[class*="notif"] .badge',
                '[class*="alert"] .badge',
                '[class*="message"] .badge'
            ].join(','));
        }

        function extractTotalCount(root) {
            var badges = badgeCandidates(root);
            for (var i = 0; i < badges.length; i++) {
                var value = parseCount(badges[i].textContent);
                if (value > 0) {
                    return value;
                }
            }

            var header = root.querySelector('header, .header, #header, nav');
            if (!header) {
                return 0;
            }

            var nodes = header.querySelectorAll('span, div, a, sup, strong, b');
            for (var j = 0; j < nodes.length; j++) {
                var value = parseCount(nodes[j].textContent);
                if (value > 0 && value < 1000) {
                    return value;
                }
            }

            return 0;
        }

        function pickPreview(container) {
            var selectors = [
                '.message',
                '.preview',
                '.description',
                '.text',
                '[class*="message"]',
                '[class*="preview"]',
                '[class*="body"]',
                'p',
                'em',
                'span'
            ];

            for (var i = 0; i < selectors.length; i++) {
                var element = container.querySelector(selectors[i]);
                var text = trimText(element && element.textContent);

                if (text && !/^\d+$/.test(text)) {
                    return text.slice(0, 220);
                }
            }

            return trimText(container.textContent).slice(0, 220);
        }

        function pickSender(container) {
            var selectors = [
                '.username',
                '.user',
                '.name',
                '[class*="username"]',
                '[class*="sender"]',
                '[class*="author"]',
                'strong',
                'b',
                'a[href*="profil"]',
                'a[href*="user"]'
            ];

            for (var i = 0; i < selectors.length; i++) {
                var element = container.querySelector(selectors[i]);
                var text = trimText(element && element.textContent);

                if (text && !/^\d+$/.test(text)) {
                    return text.slice(0, 80);
                }
            }

            return '';
        }

        function extractDetails(root) {
            var containers = root.querySelectorAll([
                '.notifications-list li',
                '.notification-item',
                '[class*="notif"] li',
                '[class*="notification"] li',
                '.dropdown-menu li',
                '.menu-dropdown li',
                '.list-group-item',
                '[class*="notification"]'
            ].join(','));

            var details = [];
            var seen = {};

            for (var i = 0; i < containers.length; i++) {
                var container = containers[i];
                var fullText = trimText(container.textContent);
                if (!fullText) continue;

                var detail = {
                    type: detectType(fullText),
                    sender: pickSender(container),
                    preview: pickPreview(container),
                    count: 1
                };

                var signature = [detail.type, detail.sender, detail.preview].join('|');
                if (seen[signature]) continue;

                seen[signature] = true;
                details.push(detail);

                if (details.length >= 10) {
                    break;
                }
            }

            return details;
        }

        function collect(root, sourceUrl) {
            return {
                totalCount: extractTotalCount(root),
                details: extractDetails(root),
                sourceUrl: sourceUrl || window.location.href
            };
        }

        function candidateUrls() {
            var urls = [window.location.href];
            var links = document.querySelectorAll('a[href]');

            for (var i = 0; i < links.length; i++) {
                var href = links[i].getAttribute('href');
                var url = normalizeUrl(href);
                var text = trimText((links[i].textContent || '') + ' ' + (href || ''));

                if (!url || url.indexOf(window.location.origin) !== 0) continue;

                if (/(notifik|upozorn|sprav|message|inbox|ts)/i.test(text) || /(notifik|upozorn|sprav|message|inbox|ts)/i.test(url)) {
                    urls.push(url);
                }
            }

            return Array.from(new Set(urls)).slice(0, 4);
        }

        function betterSnapshot(current, next) {
            if (!next) return current;
            if (!current) return next;

            if ((next.totalCount || 0) > (current.totalCount || 0)) {
                return next;
            }

            if ((next.details || []).length > (current.details || []).length) {
                return next;
            }

            var nextRichness = (next.details || []).reduce(function(total, item) {
                return total + ((item.preview || '').length);
            }, 0);

            var currentRichness = (current.details || []).reduce(function(total, item) {
                return total + ((item.preview || '').length);
            }, 0);

            return nextRichness > currentRichness ? next : current;
        }

        async function fetchSnapshot(url) {
            try {
                var response = await fetch(url, {
                    method: 'GET',
                    credentials: 'include',
                    cache: 'no-store',
                    headers: {
                        'X-Requested-With': 'BirdzApp'
                    }
                });

                if (!response.ok) {
                    return null;
                }

                var html = await response.text();
                if (!html) {
                    return null;
                }

                var parser = new DOMParser();
                var doc = parser.parseFromString(html, 'text/html');
                return collect(doc, url);
            } catch (error) {
                return null;
            }
        }

        ensureSafeArea();

        (async function() {
            var snapshot = collect(document, window.location.href);
            var urls = candidateUrls();

            for (var i = 0; i < urls.length; i++) {
                var remote = await fetchSnapshot(urls[i]);
                snapshot = betterSnapshot(snapshot, remote);
            }

            handler.postMessage(snapshot);
        })().catch(function(error) {
            handler.postMessage({
                totalCount: extractTotalCount(document),
                details: extractDetails(document),
                error: trimText(String(error || 'unknown'))
            });
        });

        return 'birdz-monitor-ran';
    })();
    """
}