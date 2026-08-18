/**
 * Blend machine hero — editor.
 *
 * No build step: this is plain ES5 against the wp.* globals, so the theme is
 * installable as-is. The editor shows editable copy plus a static schematic;
 * the canvas itself runs on the front end (see view.js).
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
	var RichText = blockEditor.RichText;
	var InspectorControls = blockEditor.InspectorControls;
	var MediaUpload = blockEditor.MediaUpload;
	var MediaUploadCheck = blockEditor.MediaUploadCheck;

	var PanelBody = components.PanelBody;
	var RangeControl = components.RangeControl;
	var ToggleControl = components.ToggleControl;
	var TextControl = components.TextControl;
	var TextareaControl = components.TextareaControl;
	var SelectControl = components.SelectControl;
	var Button = components.Button;

	var data = window.letsLapseHero || {};
	var schema = data.schema || {};

	function rule( key ) {
		return schema[ key ] || { 'default': 0, min: 0, max: 100, 'int': true };
	}

	function effective( attributes, key ) {
		return typeof attributes[ key ] === 'number' ? attributes[ key ] : rule( key )[ 'default' ];
	}

	/**
	 * A RangeControl bound to one schema-governed number.
	 *
	 * Resetting clears the attribute entirely, so the block falls back to the
	 * theme default rather than freezing today's value into the post.
	 */
	function numberControl( attributes, setAttributes, key, label, help ) {
		var spec = rule( key );

		return el( RangeControl, {
			key: key,
			label: label,
			help: help,
			value: effective( attributes, key ),
			min: spec.min,
			max: spec.max,
			step: spec[ 'int' ] ? 1 : 0.05,
			allowReset: true,
			resetFallbackValue: spec[ 'default' ],
			onChange: function ( next ) {
				var update = {};
				update[ key ] = ( next === undefined || next === null ) ? undefined : next;
				setAttributes( update );
			}
		} );
	}

	function derivedCaption( attributes ) {
		var template = data.captionTemplate ||
			'{frames} source frames · {srcFps} fps · {ratio} → 1 · {outputs} blended frames';

		return template
			.replace( '{frames}', effective( attributes, 'frameCount' ) )
			.replace( '{srcFps}', effective( attributes, 'sourceFps' ) )
			.replace( '{ratio}', effective( attributes, 'blendRatio' ) )
			.replace( '{outputs}', effective( attributes, 'outputCount' ) );
	}

	function schematic( attributes ) {
		var ratio = effective( attributes, 'blendRatio' );
		var outputs = effective( attributes, 'outputCount' );
		var strip = [];
		var outs = [];
		var i;

		for ( i = 0; i < 5; i++ ) {
			strip.push( el( 'span', { key: 'src' + i, className: 'll-hero-editor__cell' } ) );
		}

		for ( i = 0; i < Math.min( outputs, 10 ); i++ ) {
			outs.push( el( 'span', { key: 'out' + i, className: 'll-hero-editor__cell is-output' } ) );
		}

		return el(
			'div',
			{ className: 'll-hero-editor__machine' },
			el( 'span', { className: 'll-hero-editor__strip' }, strip ),
			el( 'span', { className: 'll-hero-editor__stage' }, ratio + '→1' ),
			el( 'span', { className: 'll-hero-editor__outputs' }, outs ),
			el( 'span', { className: 'll-hero-editor__legend' }, __( 'The live machine runs on the front end', 'letslapse' ) )
		);
	}

	function inspector( attributes, setAttributes ) {
		return el(
			InspectorControls,
			null,
			el(
				PanelBody,
				{ title: __( 'Layout & copy', 'letslapse' ), initialOpen: true },
				el( SelectControl, {
					label: __( 'Heading level', 'letslapse' ),
					help: __( 'Use H1 on the homepage; step down when the page already has one.', 'letslapse' ),
					value: String( attributes.headingLevel || 1 ),
					options: [
						{ label: 'H1', value: '1' },
						{ label: 'H2', value: '2' },
						{ label: 'H3', value: '3' },
						{ label: 'H4', value: '4' }
					],
					onChange: function ( next ) {
						setAttributes( { headingLevel: parseInt( next, 10 ) } );
					}
				} ),
				el( ToggleControl, {
					label: __( 'Show the caption line', 'letslapse' ),
					checked: attributes.showCaption !== false,
					onChange: function ( next ) {
						setAttributes( { showCaption: next } );
					}
				} ),
				el( TextareaControl, {
					label: __( 'Caption override', 'letslapse' ),
					help: __( 'Leave empty to derive it from the numbers below.', 'letslapse' ),
					placeholder: derivedCaption( attributes ),
					value: attributes.caption || '',
					onChange: function ( next ) {
						setAttributes( { caption: next } );
					}
				} ),
				el( ToggleControl, {
					label: __( 'Show the corner chip', 'letslapse' ),
					checked: attributes.showNote !== false,
					onChange: function ( next ) {
						setAttributes( { showNote: next } );
					}
				} ),
				el( TextControl, {
					label: __( 'Replay button label', 'letslapse' ),
					value: attributes.replayLabel || '',
					onChange: function ( next ) {
						setAttributes( { replayLabel: next } );
					}
				} )
			),
			el(
				PanelBody,
				{ title: __( 'Blend', 'letslapse' ), initialOpen: false },
				numberControl( attributes, setAttributes, 'blendRatio', __( 'Source frames per blend', 'letslapse' ), __( 'Each frame lands at 1/N opacity, so this many frames average into one output.', 'letslapse' ) ),
				numberControl( attributes, setAttributes, 'outputCount', __( 'Blended frames produced', 'letslapse' ) ),
				numberControl( attributes, setAttributes, 'sourceFps', __( 'Source capture rate (fps)', 'letslapse' ), __( 'Only used for the labels — it states what the footage was shot at.', 'letslapse' ) )
			),
			el(
				PanelBody,
				{ title: __( 'Pacing', 'letslapse' ), initialOpen: false },
				numberControl( attributes, setAttributes, 'startRate', __( 'Start rate (frames/s)', 'letslapse' ) ),
				numberControl( attributes, setAttributes, 'accel', __( 'Acceleration per blend', 'letslapse' ), __( 'rate(n) = min(max rate, start rate × accel^n)', 'letslapse' ) ),
				numberControl( attributes, setAttributes, 'maxRate', __( 'Maximum rate (frames/s)', 'letslapse' ) ),
				numberControl( attributes, setAttributes, 'playFps', __( 'Playback rate (fps)', 'letslapse' ) )
			),
			el(
				PanelBody,
				{ title: __( 'Footage', 'letslapse' ), initialOpen: false },
				el(
					MediaUploadCheck,
					null,
					el( MediaUpload, {
						allowedTypes: [ 'image' ],
						value: attributes.atlasId || 0,
						onSelect: function ( media ) {
							setAttributes( { atlasId: media.id, atlasUrl: media.url } );
						},
						render: function ( picker ) {
							return el(
								Fragment,
								null,
								el( Button, {
									variant: 'secondary',
									onClick: picker.open
								}, attributes.atlasId ? __( 'Replace sprite sheet', 'letslapse' ) : __( 'Choose sprite sheet', 'letslapse' ) ),
								attributes.atlasId ? el( Button, {
									variant: 'tertiary',
									isDestructive: true,
									onClick: function () {
										setAttributes( { atlasId: 0, atlasUrl: '' } );
									}
								}, __( 'Use theme default', 'letslapse' ) ) : null
							);
						}
					} )
				),
				el( 'p', { className: 'll-hero-editor__hint' }, __( 'A square grid of square frames, read left to right, top to bottom.', 'letslapse' ) ),
				numberControl( attributes, setAttributes, 'atlasCols', __( 'Columns in the sheet', 'letslapse' ) ),
				numberControl( attributes, setAttributes, 'frameCount', __( 'Frames to use', 'letslapse' ) ),
				numberControl( attributes, setAttributes, 'atlasFrameSize', __( 'Frame size (px)', 'letslapse' ) )
			)
		);
	}

	function Edit( props ) {
		var attributes = props.attributes;
		var setAttributes = props.setAttributes;
		var blockProps = useBlockProps( { className: 'll-hero' } );
		var level = attributes.headingLevel || 1;

		return el(
			Fragment,
			null,
			inspector( attributes, setAttributes ),
			el(
				'div',
				blockProps,
				el( RichText, {
					tagName: 'h' + level,
					className: 'll-hero__heading',
					value: attributes.heading,
					allowedFormats: [ 'core/italic', 'core/bold' ],
					placeholder: __( 'Many frames in. One frame out.', 'letslapse' ),
					onChange: function ( next ) {
						setAttributes( { heading: next } );
					}
				} ),
				el( RichText, {
					tagName: 'p',
					className: 'll-hero__standfirst',
					value: attributes.subheading,
					placeholder: __( 'One or two sentences on what the machine below is doing.', 'letslapse' ),
					onChange: function ( next ) {
						setAttributes( { subheading: next } );
					}
				} ),
				schematic( attributes ),
				el(
					'div',
					{ className: 'll-hero-editor__meta' },
					attributes.showCaption !== false
						? el( 'span', null, attributes.caption || derivedCaption( attributes ) )
						: null,
					attributes.showNote !== false
						? el( RichText, {
							tagName: 'span',
							className: 'll-hero__chip',
							value: attributes.note,
							placeholder: __( 'Corner chip', 'letslapse' ),
							onChange: function ( next ) {
								setAttributes( { note: next } );
							}
						} )
						: null
				)
			)
		);
	}

	wp.blocks.registerBlockType( 'letslapse/hero-machine', {
		edit: Edit,
		save: function () {
			return null;
		}
	} );
}( window.wp ) );
