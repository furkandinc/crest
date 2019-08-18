﻿Shader "Crest/Underwater Post Process"
{
	SubShader
	{
		// No culling or depth
		Cull Off ZWrite Off ZTest Always

		Pass
		{
			CGPROGRAM
			#pragma vertex Vert
			#pragma fragment Frag

			#pragma shader_feature _SUBSURFACESCATTERING_ON
			#pragma shader_feature _SUBSURFACESHALLOWCOLOUR_ON
			#pragma shader_feature _TRANSPARENCY_ON
			#pragma shader_feature _CAUSTICS_ON
			#pragma shader_feature _SHADOWS_ON
			#pragma shader_feature _COMPILESHADERWITHDEBUGINFO_ON

			#pragma multi_compile __ _FULL_SCREEN_EFFECT
			#pragma multi_compile __ _DEBUG_VIEW_OCEAN_MASK

			#if _COMPILESHADERWITHDEBUGINFO_ON
			#pragma enable_d3d11_debug_symbols
			#endif

			#include "UnityCG.cginc"
			#include "Lighting.cginc"
			#include "../OceanLODData.hlsl"

			float _CrestTime;
			half3 _AmbientLighting;

			#include "../OceanEmission.hlsl"

			float _OceanHeight;
			float4x4 _ViewProjection;
			float4x4 _InvViewProjection;

			struct Attributes
			{
				float4 positionOS : POSITION;
				float2 uv : TEXCOORD0;
			};

			struct Varyings
			{
				float4 positionCS : SV_POSITION;
				float2 uv : TEXCOORD0;
				float4 viewWS_oceanDistance : TEXCOORD1;
			};

			Varyings Vert (Attributes input)
			{
				Varyings output;
				output.positionCS = UnityObjectToClipPos(input.positionOS);
				output.uv = input.uv;

				{
					const float2 pixelCS = input.uv * 2 - float2(1.0, 1.0);
#if 0
					const float4 pixelWS_H = mul(_InvViewProjection, float4(pixelCS, 1.0, 1.0));
					const float3 pixelWS = (pixelWS_H.xyz/pixelWS_H.w);
					output.viewWS_oceanDistance.xyz = _WorldSpaceCameraPos - pixelWS;

					// Due to floating point precision errors, comparing the
					// height of the far plane pixel to the height of the ocean
					// has to be done in clip space, which is unfortunate as we
					// have to do two matrix multiplications to calculate the
					// ocean height value.
					//
					// NOTE: This doesn't work if the camera is rotated.
					const float3 oceanPosWS = float3(pixelWS.x, _OceanHeight, pixelWS.z);
					float4 oceanPosCS = mul(_ViewProjection, float4(oceanPosWS, 1.0));
					float oceanHeightCS = (oceanPosCS.y / oceanPosCS.w);
					output.viewWS_oceanDistance.w = pixelCS.y - oceanHeightCS;
#else

					const float4 pixelWS = mul(_InvViewProjection, float4(pixelCS, 1.0, 1.0));
					output.viewWS_oceanDistance = pixelWS.xyzy / pixelWS.w;
					output.viewWS_oceanDistance.w -= _OceanHeight;
					output.viewWS_oceanDistance.w /= 100.0;
					output.viewWS_oceanDistance.xyz = _WorldSpaceCameraPos - output.viewWS_oceanDistance.xyz;
#endif

				}

				return output;
			}

			sampler2D _MainTex;
			sampler2D _MaskTex;
			sampler2D _MaskDepthTex;

			// In-built Unity textures
			sampler2D _CameraDepthTexture;
			sampler2D _Normals;

			half3 ApplyUnderwaterEffect(half3 sceneColour, const float sceneZ01, const half3 view, bool isOceanSurface)
			{
				const float sceneZ = LinearEyeDepth(sceneZ01);
				const float3 lightDir = _WorldSpaceLightPos0.xyz;

				float3 surfaceAboveCamPosWorld = 0.0;
				half3 scatterCol = 0.0;
				{
					half sss = 0.;
					const float3 uv_slice = WorldToUV(_WorldSpaceCameraPos.xz);
					SampleDisplacements(_LD_TexArray_AnimatedWaves, uv_slice, 1.0, surfaceAboveCamPosWorld, sss);
					surfaceAboveCamPosWorld.y += _OceanCenterPosWorld.y;

					// depth and shadow are computed in ScatterColour when underwater==true, using the LOD1 texture.
					const float depth = 0.0;
					const half shadow = 1.0;

					scatterCol = ScatterColour(surfaceAboveCamPosWorld, depth, _WorldSpaceCameraPos, lightDir, view, shadow, true, true, sss);
				}

#if _CAUSTICS_ON
				if (sceneZ01 != 0.0 && !isOceanSurface)
				{
					ApplyCaustics(view, lightDir, sceneZ, _Normals, true, sceneColour);
				}
#endif // _CAUSTICS_ON

				return lerp(sceneColour, scatterCol, 1.0 - exp(-_DepthFogDensity.xyz * sceneZ));
			}

			fixed4 Frag (Varyings input) : SV_Target
			{
				// test - override our interpolated value with a freshly computed value here
				{
					const float2 pixelCS = input.uv * 2 - float2(1.0, 1.0);
					const float4 pixelWS = mul(_InvViewProjection, float4(pixelCS, 1.0, 1.0));
					input.viewWS_oceanDistance = pixelWS.xyzy / pixelWS.w;
					input.viewWS_oceanDistance.w -= _OceanHeight;
					input.viewWS_oceanDistance.xyz = _WorldSpaceCameraPos - input.viewWS_oceanDistance.xyz;
				}


				#if !_FULL_SCREEN_EFFECT
				const bool isBelowHorizon = (input.viewWS_oceanDistance.w <= 0.0);
				#else
				const bool isBelowHorizon = true;
				#endif

				half3 sceneColour = tex2D(_MainTex, input.uv).rgb;

				float sceneZ01 = tex2D(_CameraDepthTexture, input.uv).x;
				bool isUnderwater = false;
				bool isOceanSurface = false;
				{
					int mask = tex2D(_MaskTex, input.uv);
					const float oceanDepth01 = tex2D(_MaskDepthTex, input.uv);
					isOceanSurface = mask != 0 && (sceneZ01 < oceanDepth01);
					isUnderwater = mask == 2 || (isBelowHorizon && mask != 1);
					sceneZ01 = isOceanSurface ? oceanDepth01 : sceneZ01;
				}
#if _DEBUG_VIEW_OCEAN_MASK
				int mask = tex2D(_MaskTex, input.uv);
				if(!isOceanSurface)
				{
					return float4(sceneColour * float3(isUnderwater * 0.5, (1.0 - isUnderwater) * 0.5, 1.0), 1.0);
				}
				else
				{
					return float4(sceneColour * float3(mask == 1, mask == 2, 0.0), 1.0);
				}
#else
				if(isUnderwater)
				{
					const half3 view = normalize(input.viewWS_oceanDistance.xyz);
					sceneColour = ApplyUnderwaterEffect(sceneColour, sceneZ01, view, isOceanSurface);
				}

				return half4(sceneColour, 1.0);
#endif // _DEBUG_VIEW_OCEAN_MASK
			}
			ENDCG
		}
	}
}