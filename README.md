# Waypaper

App de wallpapers de vídeo para macOS 13+, com biblioteca local em SwiftUI, reprodução por monitor em AppKit/AVFoundation e nitidez opcional via Core Image. Sem dependências externas, conta ou servidor.

## Usar

Abra o app e importe vídeos pelo botão **Importar vídeos** ou arrastando arquivos para a biblioteca. O Waypaper guarda uma cópia em `~/Library/Application Support/Waypaper/media/`; mover o arquivo original não quebra o wallpaper.

1. Selecione um monitor na lateral.
2. Escolha um wallpaper na biblioteca. As miniaturas são estáticas; **Reproduzir prévia** (ou Espaço) inicia somente o vídeo selecionado.
3. Clique em **Aplicar ao monitor**.
4. Em **Neste monitor**, escolha **Preencher** (recorta bordas) ou **Ajustar** (mantém o vídeo inteiro, com barras se necessário), pausa e nitidez.
5. **Restaurar fundo** remove a janela de vídeo, revelando o wallpaper original do macOS.

O ícone de onda/W na barra de menus abre a biblioteca, importa arquivos, pausa/retoma todos os monitores ou encerra o app. Fechar a janela da biblioteca não encerra os wallpapers; a prévia é pausada ao ocultar/fechar/minimizar a janela. Remover um wallpaper da biblioteca remove suas cópias gerenciadas e suas associações aos monitores, nunca o arquivo original.

### Monitores e energia

- Cada monitor independente tem seu próprio player, loop, wallpaper, pausa, enquadramento e nitidez.
- As associações são salvas por UUID de monitor e preservadas quando ele é desconectado. A reprodução desconectada é liberada, não transferida para outra tela.
- Reconectar restaura a associação. Monitores espelhados compartilham o destino de reprodução, sem player duplicado para o espelho.
- Alterar resolução/escala atualiza a janela e a escala Retina sem reconstruir os players não afetados.
- Suspensão/desligamento da tela e inatividade de sessão têm bloqueios separados. A retomada nunca desfaz a pausa manual.
- Com **Reduzir movimento** ativo, a primeira aplicação em um monitor começa pausada.
- Vídeos são sempre reproduzidos sem áudio. Não há agentes, serviços ou inicialização automática instalados.

### Qualidade

**Nitidez** é um filtro `CIUnsharpMask`, opcional e desligado por padrão. Zero reproduz o vídeo sem composição de filtro. O ajuste não recomprime nem modifica o arquivo; a composição preserva a cadência informada pelo vídeo. A aplicação do filtro pode reiniciar o loop.

Não é super-resolução por IA, nem prova de que o iWallpaper faça enhancement. Pode realçar ruído/halos e aumentar o uso da GPU; compare com **Original** antes de manter uma intensidade alta. O enquadramento e a escala Retina são tratados explicitamente.

## Desenvolvimento

Requer ferramentas de desenvolvimento Apple e Swift 5.9 ou superior:

```sh
swift run Waypaper
```

Para importar e aplicar um arquivo diretamente ao primeiro monitor da lista:

```sh
swift run Waypaper "himmel-x-frieren-beyond-the-journeys-end-moewalls-com.mp4"
```

Passar um arquivo importa uma nova cópia. A preferência antiga `videoPath`, se existir no mesmo domínio de preferências, é importada uma vez quando a biblioteca está vazia. A biblioteca e as associações ficam em `manifest.json` e `displays.json` dentro de `Application Support/Waypaper`. Arquivos de estado corrompidos são reportados e não sobrescritos silenciosamente.

### Organização

```text
Sources/Waypaper/
  App/         entrada, ciclo de vida, menu e smoke check integrado
  Library/     modelo, validação, importação, miniaturas e persistência
  Playback/    identidade dos monitores, coordenação, sessões e camada de vídeo
  UI/          biblioteca SwiftUI e prévia AVKit
  Resources/   ícones PNG e ICNS
scripts/       empacotamento e conversão do ícone
```

Estado de interface e reprodução é isolado no `@MainActor`. Cópia/análise dos vídeos e geração de miniaturas ocorrem fora do ator principal. Importações são serializadas, canceláveis e publicadas apenas após persistência bem-sucedida. A interface não cria players de desktop: essa responsabilidade pertence a `DisplayCoordinator` e `WallpaperSession`.

## Distribuir: DMG ou ZIP

No Mac de desenvolvimento, com Python 3 e as ferramentas Apple:

```sh
python3 scripts/package.py
```

Gera **`dist/Waypaper.dmg`** e **`dist/Waypaper.zip`**, versão 1.1.0, compilados em release para Apple Silicon (M1 e posteriores), com recursos SwiftPM, ícone e assinatura ad hoc. Vídeos da biblioteca não fazem parte do pacote.

Para instalar:

1. Encerre a versão anterior pelo menu Waypaper.
2. Abra o DMG e arraste **Waypaper.app** para **Applications/Aplicativos**. Alternativamente, descompacte o ZIP e mova o app.
3. Abra o aplicativo. Não é necessário instalar Swift, Python ou Xcode no Mac destinatário.
4. Se o macOS bloquear por desenvolvedor não verificado, após tentar abrir use **Ajustes do Sistema → Privacidade e Segurança → Abrir Mesmo Assim**, apenas para um pacote de origem confiável. Não desative o Gatekeeper.

DMG não substitui Developer ID nem notarização; os avisos de segurança continuam possíveis. Para atualizar, encerre e substitua o app. Para remover, encerre e apague o app; a biblioteca em `Application Support/Waypaper` é mantida até você decidir apagá-la.
Verificado localmente: build debug e release, assinatura do ZIP extraído, montagem somente leitura do DMG, atalho para Aplicativos e smoke completo executado diretamente do app no DMG. O teste também ocultou temporariamente o bundle de recursos do ambiente de desenvolvimento, confirmando que o app distribuído carrega seus próprios recursos.


## Verificação executável

Com uma sessão gráfica ativa e um vídeo curto:

```sh
swift run Waypaper --smoke-test "himmel-x-frieren-beyond-the-journeys-end-moewalls-com.mp4"
```

O check usa uma biblioteca temporária e não altera sua biblioteca real. Exercita importação/cópia, miniatura, reabertura do manifesto, rejeição de arquivo inválido e de caminho inseguro, proteção de manifesto corrompido, cancelamento, reprodução real, pausa, sessões independentes, configuração de monitor desconectado, nitidez/cadência, loop, reconexão simulada e remoção sem apagar o original. Também abre a interface SwiftUI, captura sua janela, aciona a prévia pelo atalho de teclado e verifica a pausa da prévia ao ocultá-la. Imprime `PASS` ou encerra com código 1. A espera de loop tem limite de 90 segundos.

**Limite da verificação local:** há apenas uma tela física neste ambiente. Duas sessões reais são exercitadas nessa tela e desconexão/reconexão é simulada via a mesma reconciliação usada pelas notificações do sistema. Dois monitores físicos, hot-plug real, espelhamento, Spaces/Mission Control e bloqueio/suspensão reais precisam de validação nesse hardware. A captura de NSView não comprova a composição final dos planos de vídeo do WindowServer.

Sem detecção de oclusão do wallpaper por outras janelas, política automática de bateria, catálogo remoto ou super-resolução. Cada monitor ativo decodifica seu vídeo; vários vídeos 4K/60 e nitidez aumentam o consumo. Monitores sem UUID ou serial usam identificação transitória e podem exigir nova associação após reconectar/reiniciar.

## Identidade visual

O ícone foi gerado com a ferramenta integrada **image_gen**, acionada pela CLI do Codex com a skill `imagegen`, sem fallback de API ou chave externa. A arte hero existente foi preservada.

- Master gerado: `assets/images/waypaper-app-icon-master.png`.
- Ícones do aplicativo: `Sources/Waypaper/Resources/AppIcon.png` e `AppIcon.icns`.
- Ícone monocromático da barra: desenho nativo em `AppIdentity`, adaptado ao tema do sistema.

O master original permanece intacto; os derivados recebem transparência fora do quadrado arredondado. Para regenerar os derivados:

```sh
python3 scripts/make_app_icon.py --mask-from assets/images/waypaper-app-icon-master.png
```

Prompt visual enviado ao Codex/imagegen (a imagem hero foi fornecida como referência):

```text
Use the built-in imagegen skill and built-in image_gen tool only (NOT CLI fallback, NOT OPENAI_API_KEY). Generate exactly one macOS app icon master image.

Use case: logo-brand
Asset type: macOS app icon master (1024x1024 PNG)
Primary request: Simple stylized letter W formed by a smooth flowing wave ribbon; minimal geometric mark readable at 16px; no text labels, no wordmarks, no wallpaper scene
Input images: Image 1: reference for aurora teal/cyan/violet palette and soft glow mood only — do not copy the full hero composition
Style/medium: flat vector-like illustration, crisp edges, subtle inner glow
Composition/framing: centered mark on rounded-square app-icon canvas with comfortable padding; square 1:1
Lighting/mood: soft aurora glow on dark blue-violet background
Color palette: teal, cyan, violet accents on deep indigo base (inspired by reference)
Constraints: must read as W+wave at small sizes; no photographs; no UI chrome; no watermark
Avoid: busy wallpaper imagery, tiny illegible detail, text, dock mockups
```

Arquivos de vídeo e artefatos de compilação/distribuição são ignorados pelo Git. O aplicativo não concede direitos de uso ou redistribuição das mídias importadas.
