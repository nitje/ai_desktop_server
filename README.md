# ai_desktop_server
ai_desktop_server with vllm-webgui(docker) | LM Studio | VS Code | ComfyUI ... RTX 6000 Pro Workstation optimized
<br><br><br>
Vorraussetzung:<br>
Debian 13.5 mit Desktop gnome ist Vorinstalliert
<br><br>
Video zum Setup: https://youtu.be/MUCXDlkUb0w
<br>
Video zum Setup in Visual Studio Code: https://youtu.be/IvAOa-rEq-c
<br><br><br>
Im Persöhnlichen Ordner wird auch ein link zu ComfyUI erstellt wo ihr Model und output findet.
<br><br><br>
GGUF option hinzugefügt ist aber in BETA
<br>
<br>
vLLM Zusatzargumente:
<br>
# OpenAI/GPT-OSS-120B #
<br>

--gpu-memory-utilization 0.88 --max-model-len 131072 --max-num-seqs 1 --max-num-batched-tokens 8192 --enable-auto-tool-choice --tool-call-parser openai
<br>
# Qwen/Qwen3-Coder-Next-FP8 #
<br>

--gpu-memory-utilization 0.88 --max-model-len 131072 --max-num-seqs 1 --max-num-batched-tokens 8192 --enable-auto-tool-choice --tool-call-parser qwen3_coder
<br>
# optional:

--max-num-seqs 2

--enable-reasoning

--reasoning-parser qwen3

--kv-cache-dtype fp8

--kv-cache-dtype fp8_e4m3
<br><br><br>
# Bilder:
<br>
ComfyUi:
<img src="https://interceptor.marconitschke.de/attachment.php?aid=824" alt="ai_desktop_server_rtx6000pro_workstation_comfyui">
<br><br><br>
GGUF integration:
<img src="https://interceptor.marconitschke.de/attachment.php?aid=827" alt="ai_desktop_server_rtx6000pro_workstation_gguf">
<br><br>
GGUF integration mit Link:
<img src="https://interceptor.marconitschke.de/attachment.php?aid=828" alt="ai_desktop_server_rtx6000pro_workstation_gguf_link">
<br><br>
Kodierung mit VS-Code-1:
<img src="https://interceptor.marconitschke.de/attachment.php?aid=829" alt="ai_desktop_server_rtx6000pro_workstation_120b_tetris">
<br><br>
Kodierung mit VS-Code-2:
<img src="https://interceptor.marconitschke.de/attachment.php?aid=830" alt="ai_desktop_server_rtx6000pro_workstation_qwen3_coder_next_tetris">
<br><br>
Startzeit:
<img src="https://interceptor.marconitschke.de/attachment.php?aid=831" alt="ai_desktop_server_rtx6000pro_workstation_timer_indicator">
<br><br>
Sytemauslastung & Settings:
<img src="https://interceptor.marconitschke.de/attachment.php?aid=833" alt="ai_desktop_server_rtx6000pro_workstation_display_system_load">
<br>
