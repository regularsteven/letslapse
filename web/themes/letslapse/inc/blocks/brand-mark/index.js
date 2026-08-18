/**
 * Brand mark — editor.
 *
 * Plain ES5 against the wp.* globals, no build step. The preview is the same
 * <img> the server renders, pointed at the same theme file.
 */
( function ( wp ) {
	'use strict';

	if ( ! wp || ! wp.blocks || ! wp.element ) {
		return;
	}

	var el = wp.element.createElement;
	var Fragment = wp.element.Fragment;
	var __ = wp.i18n.__;
	var blockEditor = wp.blockEditor;
	var components = wp.components;

	var useBlockProps = blockEditor.useBlockProps;
	var InspectorControls = blockEditor.InspectorControls;

	var PanelBody = components.PanelBody;
	var RangeControl = components.RangeControl;
	var SelectControl = components.SelectControl;
	var ToggleControl = components.ToggleControl;
	var TextControl = components.TextControl;

	var data = window.letsLapseBrandMark || {};
	var sources = data.sources || {};

	function source( variant ) {
		return sources[ variant === 'light' ? 'light' : 'dark' ] || '';
	}

	function Edit( props ) {
		var attributes = props.attributes;
		var setAttributes = props.setAttributes;
		var size = attributes.size || 32;
		var classes = 'll-brand-mark' + ( attributes.rounded !== false ? ' is-rounded' : '' );

		var blockProps = useBlockProps( {
			className: classes,
			src: source( attributes.variant ),
			width: size,
			height: size,
			alt: attributes.label || ''
		} );

		return el(
			Fragment,
			null,
			el(
				InspectorControls,
				null,
				el(
					PanelBody,
					{ title: __( 'Mark', 'letslapse' ), initialOpen: true },
					el( SelectControl, {
						label: __( 'Version', 'letslapse' ),
						value: attributes.variant,
						options: [
							{ label: __( 'Dark — for dark backgrounds', 'letslapse' ), value: 'dark' },
							{ label: __( 'Light — for light backgrounds', 'letslapse' ), value: 'light' }
						],
						onChange: function ( next ) {
							setAttributes( { variant: next } );
						}
					} ),
					el( RangeControl, {
						label: __( 'Size (px)', 'letslapse' ),
						value: size,
						min: 12,
						max: 512,
						step: 2,
						allowReset: true,
						resetFallbackValue: 32,
						onChange: function ( next ) {
							setAttributes( { size: ( next === undefined || next === null ) ? 32 : next } );
						}
					} ),
					el( ToggleControl, {
						label: __( 'Round the corners', 'letslapse' ),
						help: __( 'The icon ships as a full square plate, the way the App Store shows it before masking.', 'letslapse' ),
						checked: attributes.rounded !== false,
						onChange: function ( next ) {
							setAttributes( { rounded: next } );
						}
					} ),
					el( TextControl, {
						label: __( 'Alt text', 'letslapse' ),
						help: __( 'Leave empty when the mark sits next to the site name — then it is decorative and screen readers skip it.', 'letslapse' ),
						value: attributes.label || '',
						onChange: function ( next ) {
							setAttributes( { label: next } );
						}
					} )
				)
			),
			el( 'img', blockProps )
		);
	}

	wp.blocks.registerBlockType( 'letslapse/brand-mark', {
		edit: Edit,
		save: function () {
			return null;
		}
	} );
}( window.wp ) );
