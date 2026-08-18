<?php
/**
 * Server render for letslapse/brand-mark.
 *
 * Theme-relative on purpose: a block template part cannot resolve
 * get_theme_file_uri() on its own, and a hard-coded absolute URL would break
 * the moment the site moved domain.
 *
 * @var array    $attributes Block attributes.
 * @var string   $content    Inner content (unused).
 * @var WP_Block $block      Block instance.
 *
 * @package LetsLapse
 */

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

$ll_variant = ( isset( $attributes['variant'] ) && 'light' === $attributes['variant'] ) ? 'light' : 'dark';
$ll_size    = isset( $attributes['size'] ) ? (int) $attributes['size'] : 32;
$ll_size    = max( 12, min( 512, $ll_size ) );
$ll_label   = isset( $attributes['label'] ) ? trim( (string) $attributes['label'] ) : '';
$ll_rounded = ! isset( $attributes['rounded'] ) || $attributes['rounded'];

$ll_classes = 'll-brand-mark';

if ( $ll_rounded ) {
	$ll_classes .= ' is-rounded';
}

$ll_wrapper = get_block_wrapper_attributes( array( 'class' => $ll_classes ) );

printf(
	/*
	 * An empty label is the default and the common case: beside the site title,
	 * the mark says nothing the title has not already said.
	 */
	'<img %1$s src="%2$s" width="%3$d" height="%3$d" alt="%4$s"%5$s decoding="async" />',
	$ll_wrapper, // phpcs:ignore WordPress.Security.EscapeOutput.OutputNotEscaped
	esc_url( get_theme_file_uri( 'assets/img/letslapse-icon-' . $ll_variant . '.svg' ) ),
	(int) $ll_size,
	esc_attr( $ll_label ),
	'' === $ll_label ? ' aria-hidden="true"' : ''
);
