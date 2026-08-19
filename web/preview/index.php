<?php
/**
 * Standalone preview harness — NOT part of the theme.
 *
 * Renders templates/front-page.html without a WordPress install so the hero can
 * be checked in a browser. It stubs the handful of WP functions the theme
 * touches and approximates the block markup WordPress would emit (see
 * wp-approx.css). Treat it as a visual smoke test, not as proof of WP output.
 *
 *   php -S localhost:8787 -t web
 *   open http://localhost:8787/preview/
 */

define( 'ABSPATH', __DIR__ . '/' );
define( 'LETSLAPSE_VERSION', 'preview' );

$theme_dir = dirname( __DIR__ ) . '/themes/letslapse';
$theme_uri = '/themes/letslapse';

// --- WP function stubs ---------------------------------------------------

function __( $text, $domain = null ) { return $text; }
function esc_html( $t ) { return htmlspecialchars( (string) $t, ENT_QUOTES, 'UTF-8' ); }
function esc_attr( $t ) { return htmlspecialchars( (string) $t, ENT_QUOTES, 'UTF-8' ); }
function esc_url( $u ) { return htmlspecialchars( (string) $u, ENT_QUOTES, 'UTF-8' ); }
function esc_url_raw( $u ) { return $u; }
function wp_kses_post( $t ) { return $t; }
function wp_json_encode( $d ) { return json_encode( $d, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES ); }
function number_format_i18n( $n ) { return number_format( (float) $n, ( (float) $n == (int) $n ) ? 0 : 1 ); }
function apply_filters( $tag, $value ) { return $value; }
function add_action() {}
function add_filter() {}
function wp_get_attachment_url() { return false; }
function get_theme_file_path( $p = '' ) { global $theme_dir; return $theme_dir . '/' . ltrim( $p, '/' ); }
function get_theme_file_uri( $p = '' ) { global $theme_uri; return $theme_uri . '/' . ltrim( $p, '/' ); }
function add_shortcode() {}
function register_block_type() {}
function register_block_style() {}
function register_block_pattern_category() {}

/**
 * Sample media, because the harness has no database.
 *
 * Only the attachments the homepage pattern asks for. Set
 * LETSLAPSE_UPLOADS_BASE if your uploads live somewhere other than the local
 * WordPress install.
 */
$preview_uploads = array(
	71 => array( 'full' => 'LetsLapse-and-battery-back-_DSC3642.jpg',            'large' => 'LetsLapse-and-battery-back-_DSC3642-1024x683.jpg' ),
	73 => array( 'full' => 'Mounted-in-the-shrubs-_DSC3647.jpg',                 'large' => 'Mounted-in-the-shrubs-_DSC3647-1024x683.jpg' ),
	76 => array( 'full' => 'Pi-Zero-and-HQ-Camera-facing-the-sunset-_DSC3423.jpg','large' => 'Pi-Zero-and-HQ-Camera-facing-the-sunset-_DSC3423-1024x683.jpg' ),
	79 => array( 'full' => 'Regular-tripod-mount-on-the-beach-_DSC3447.jpg',      'large' => 'Regular-tripod-mount-on-the-beach-_DSC3447-1024x683.jpg' ),
	80 => array( 'full' => 'Resting-on-the-rocks-_DSC3425.jpg',                   'large' => 'Resting-on-the-rocks-_DSC3425-1024x683.jpg' ),
	83 => array( 'full' => 'Looking-over-the-ocean-_DSC3641.jpg',                 'large' => 'Looking-over-the-ocean-_DSC3641-1024x512.jpg' ),
);

function wp_get_attachment_image_url( $id, $size = 'full' ) {
	global $preview_uploads;

	if ( ! isset( $preview_uploads[ (int) $id ] ) ) {
		return false;
	}

	$sizes = $preview_uploads[ (int) $id ];
	$file  = isset( $sizes[ $size ] ) ? $sizes[ $size ] : reset( $sizes );
	$base  = getenv( 'LETSLAPSE_UPLOADS_BASE' );

	return ( $base ? rtrim( $base, '/' ) . '/' : 'https://letslapse.test/wp-content/uploads/2021/07/' ) . $file;
}

function wp_get_attachment_image( $id, $size = 'full', $icon = false, $attr = array() ) {
	$url = wp_get_attachment_image_url( $id, $size );

	if ( ! $url ) {
		return '';
	}

	$out = '';

	foreach ( (array) $attr as $key => $value ) {
		$out .= sprintf( ' %s="%s"', $key, esc_attr( $value ) );
	}

	return '<img src="' . esc_url( $url ) . '"' . $out . ' />';
}

function get_block_wrapper_attributes( $extra = array() ) {
	global $preview_block, $preview_block_attributes;

	$class = 'wp-block-' . str_replace( '/', '-', $preview_block ? $preview_block : 'letslapse/hero-machine' );

	if ( ! empty( $extra['class'] ) ) {
		$class .= ' ' . $extra['class'];
	}

	// WordPress folds the block's own className in through block supports.
	if ( ! empty( $preview_block_attributes['className'] ) ) {
		$class .= ' ' . $preview_block_attributes['className'];
	}

	$out = 'class="' . esc_attr( $class ) . '"';

	if ( ! empty( $extra['style'] ) ) {
		$out .= ' style="' . esc_attr( $extra['style'] ) . '"';
	}

	return $out;
}

require_once $theme_dir . '/inc/config.php';
require_once $theme_dir . '/inc/blocks/rig-hero/rig.php';
require_once $theme_dir . '/inc/blocks.php';

$preview_block            = '';
$preview_block_attributes = array();

// --- Minimal block-markup renderer ---------------------------------------

/**
 * Render one theme block through its own render.php.
 *
 * @param string $slug    Directory under inc/blocks/.
 * @param string $json    Raw attribute JSON from the block comment.
 * @param string $content Rendered inner blocks, for blocks that take them.
 * @return string
 */
function preview_block( $slug, $json, $content = '' ) {
	global $preview_block, $preview_block_attributes;

	$attributes = $json ? json_decode( $json, true ) : array();

	if ( ! is_array( $attributes ) ) {
		$attributes = array();
	}

	// block.json defaults, applied the way WordPress would.
	$defaults = json_decode( file_get_contents( get_theme_file_path( 'inc/blocks/' . $slug . '/block.json' ) ), true );

	foreach ( $defaults['attributes'] as $key => $spec ) {
		if ( array_key_exists( 'default', $spec ) && ! isset( $attributes[ $key ] ) ) {
			$attributes[ $key ] = $spec['default'];
		}
	}

	$preview_block            = $defaults['name'];
	$preview_block_attributes = $attributes;
	$block                    = null;

	ob_start();
	include get_theme_file_path( 'inc/blocks/' . $slug . '/render.php' );
	$out = ob_get_clean();

	$preview_block            = '';
	$preview_block_attributes = array();

	return $out;
}

/**
 * Approximate the layout classes/styles WordPress generates for a block.
 *
 * @param array $attrs Block attributes from the comment JSON.
 * @return string Inline style attribute, or ''.
 */
function preview_layout_style( $attrs ) {
	if ( empty( $attrs['layout']['type'] ) || 'flex' !== $attrs['layout']['type'] ) {
		return '';
	}

	$layout  = $attrs['layout'];
	$justify = isset( $layout['justifyContent'] ) ? $layout['justifyContent'] : 'left';
	$map     = array( 'left' => 'flex-start', 'right' => 'flex-end', 'center' => 'center', 'space-between' => 'space-between' );
	$gap     = isset( $attrs['style']['spacing']['blockGap'] ) ? $attrs['style']['spacing']['blockGap'] : 'var(--wp--style--block-gap)';

	$rules = array(
		'display:flex',
		'flex-wrap:' . ( isset( $layout['flexWrap'] ) && 'nowrap' === $layout['flexWrap'] ? 'nowrap' : 'wrap' ),
		'align-items:' . ( isset( $layout['verticalAlignment'] ) && 'center' === $layout['verticalAlignment'] ? 'center' : 'center' ),
		'gap:' . $gap,
		'justify-content:' . ( isset( $map[ $justify ] ) ? $map[ $justify ] : 'flex-start' ),
	);

	return ' style="' . esc_attr( implode( ';', $rules ) ) . '"';
}

/**
 * Turn serialized block markup into HTML.
 *
 * Static core blocks already carry their own saved HTML, so most of this is
 * comment stripping; only the dynamic blocks the homepage uses are rendered.
 *
 * @param string $markup Serialized blocks.
 * @return string
 */
function preview_render_blocks( $markup ) {
	// Template parts.
	$markup = preg_replace_callback(
		'#<!--\s*wp:template-part\s+(\{[^\n]*\})\s*/-->#',
		function ( $m ) {
			$attrs = json_decode( $m[1], true );
			$slug  = isset( $attrs['slug'] ) ? $attrs['slug'] : '';
			$tag   = isset( $attrs['tagName'] ) ? $attrs['tagName'] : 'div';
			$path  = get_theme_file_path( 'parts/' . $slug . '.html' );

			if ( ! file_exists( $path ) ) {
				return '';
			}

			return '<' . $tag . ' class="wp-block-template-part">' .
				preview_render_blocks( file_get_contents( $path ) ) .
				'</' . $tag . '>';
		},
		$markup
	);

	// post-content: the homepage body now lives in the page, and the pattern is
	// the canonical copy of it.
	$markup = preg_replace_callback(
		'#<!--\s*wp:post-content\s*(\{[^\n]*\})?\s*/-->#',
		function () {
			/*
			 * Included, not read: the pattern resolves its image URLs through
			 * PHP so it stays right on whichever install renders it.
			 */
			ob_start();
			include get_theme_file_path( 'patterns/homepage.php' );
			$body = ob_get_clean();

			return '<div class="entry-content wp-block-post-content is-layout-constrained has-global-padding">' .
				preview_render_blocks( $body ) .
				'</div>';
		},
		$markup
	);

	// The machine.
	$markup = preg_replace_callback(
		'#<!--\s*wp:letslapse/hero-machine\s*(\{[^\n]*\})?\s*/-->#',
		function ( $m ) {
			return preview_block( 'hero-machine', isset( $m[1] ) ? $m[1] : '' );
		},
		$markup
	);

	// The rig hero, which wraps its copy.
	$markup = preg_replace_callback(
		'#<!--\s*wp:letslapse/rig-hero\s*(\{[^\n]*\})?\s*-->(.*?)<!--\s*/wp:letslapse/rig-hero\s*-->#s',
		function ( $m ) {
			return preview_block(
				'rig-hero',
				isset( $m[1] ) ? $m[1] : '',
				preview_render_blocks( $m[2] )
			);
		},
		$markup
	);

	// The brand mark.
	$markup = preg_replace_callback(
		'#<!--\s*wp:letslapse/brand-mark\s*(\{[^\n]*\})?\s*/-->#',
		function ( $m ) {
			return preview_block( 'brand-mark', isset( $m[1] ) ? $m[1] : '' );
		},
		$markup
	);

	// Site title.
	$markup = preg_replace(
		'#<!--\s*wp:site-title\s*(\{[^\n]*\})?\s*/-->#',
		'<p class="wp-block-site-title"><a href="/preview/">LetsLapse</a></p>',
		$markup
	);

	// Navigation: collect the links, drop the wrapper comments.
	$markup = preg_replace_callback(
		'#<!--\s*wp:navigation\s*(\{[^\n]*\})?\s*-->(.*?)<!--\s*/wp:navigation\s*-->#s',
		function ( $m ) {
			$attrs = ! empty( $m[1] ) ? json_decode( $m[1], true ) : array();
			$items = '';

			preg_match_all( '#<!--\s*wp:navigation-link\s+(\{.*?\})\s*/-->#s', $m[2], $links, PREG_SET_ORDER );

			foreach ( $links as $link ) {
				$link_attrs = json_decode( $link[1], true );
				$class      = 'wp-block-navigation-item';

				if ( ! empty( $link_attrs['className'] ) ) {
					$class .= ' ' . $link_attrs['className'];
				}

				$items .= '<li class="' . esc_attr( $class ) . '"><a class="wp-block-navigation-item__content" href="' .
					esc_url( $link_attrs['url'] ) . '">' . esc_html( $link_attrs['label'] ) . '</a></li>';
			}

			return '<nav class="wp-block-navigation"' . preview_layout_style( is_array( $attrs ) ? $attrs : array() ) .
				'><ul class="wp-block-navigation__container">' . $items . '</ul></nav>';
		},
		$markup
	);

	// Flex layouts on groups: emulate the container styles core generates.
	$markup = preg_replace_callback(
		'#<!--\s*wp:group\s+(\{[^\n]*\})\s*-->\s*<(\w+)([^>]*)>#',
		function ( $m ) {
			$attrs = json_decode( $m[1], true );
			$style = preview_layout_style( is_array( $attrs ) ? $attrs : array() );

			return '<' . $m[2] . $m[3] . $style . '>';
		},
		$markup
	);

	// Buttons wrapper is a flex layout too.
	$markup = str_replace(
		'<div class="wp-block-buttons">',
		'<div class="wp-block-buttons" style="display:flex;flex-wrap:wrap;gap:var(--wp--style--block-gap);justify-content:center">',
		$markup
	);

	// Everything else is static markup behind comments.
	return preg_replace( '#<!--\s*/?wp:.*?-->#s', '', $markup );
}

/**
 * CSS custom properties WordPress would generate from theme.json.
 *
 * @return string
 */
function preview_theme_json_vars() {
	$json = json_decode( file_get_contents( get_theme_file_path( 'theme.json' ) ), true );
	$out  = array();

	foreach ( $json['settings']['color']['palette'] as $color ) {
		$out[] = '--wp--preset--color--' . $color['slug'] . ':' . $color['color'];
	}

	foreach ( $json['settings']['typography']['fontFamilies'] as $family ) {
		$out[] = '--wp--preset--font-family--' . $family['slug'] . ':' . $family['fontFamily'];
	}

	foreach ( $json['settings']['typography']['fontSizes'] as $size ) {
		$value = $size['size'];

		if ( isset( $size['fluid']['min'] ) ) {
			$value = 'clamp(' . $size['fluid']['min'] . ', 2.5vw, ' . $size['fluid']['max'] . ')';
		}

		$out[] = '--wp--preset--font-size--' . $size['slug'] . ':' . $value;
	}

	foreach ( $json['settings']['spacing']['spacingSizes'] as $space ) {
		$out[] = '--wp--preset--spacing--' . $space['slug'] . ':' . $space['size'];
	}

	$padding = $json['styles']['spacing']['padding'];

	$out[] = '--wp--style--root--padding-left:' . $padding['left'];
	$out[] = '--wp--style--root--padding-right:' . $padding['right'];
	$out[] = '--wp--style--block-gap:' . $json['styles']['spacing']['blockGap'];
	$out[] = '--wp--style--global--content-size:' . $json['settings']['layout']['contentSize'];

	return ':root{' . implode( ';', $out ) . '}';
}

$body = preview_render_blocks( file_get_contents( get_theme_file_path( 'templates/front-page.html' ) ) );

// The main group carries global padding in a real block theme.
$body = preg_replace(
	'#<main class="([^"]*)">#',
	'<main class="$1 is-layout-constrained has-global-padding">',
	$body
);
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LetsLapse homepage — preview</title>
<style><?php echo preview_theme_json_vars(); // phpcs:ignore ?></style>
<link rel="stylesheet" href="/preview/wp-approx.css">
<link rel="stylesheet" href="<?php echo esc_url( get_theme_file_uri( 'style.css' ) ); ?>">
<link rel="stylesheet" href="<?php echo esc_url( get_theme_file_uri( 'inc/blocks/hero-machine/style.css' ) ); ?>">
<link rel="stylesheet" href="<?php echo esc_url( get_theme_file_uri( 'inc/blocks/rig-hero/style.css' ) ); ?>">
<link rel="stylesheet" href="<?php echo esc_url( get_theme_file_uri( 'inc/blocks/brand-mark/style.css' ) ); ?>">
</head>
<body class="wp-site-blocks">
<?php echo $body; // phpcs:ignore ?>
<script src="<?php echo esc_url( get_theme_file_uri( 'inc/blocks/hero-machine/view.js' ) ); ?>"></script>
<script src="<?php echo esc_url( get_theme_file_uri( 'inc/blocks/rig-hero/view.js' ) ); ?>"></script>
</body>
</html>
