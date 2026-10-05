# Waypaper

Wallpaper de vídeo local para macOS 13+, em Swift/AppKit/AVFoundation, sem dependências externas.

## Executar

Instale as ferramentas de desenvolvimento da Apple (`xcode-select --install`), se necessário. Na pasta do projeto:

```sh
swift run Waypaper "himmel-x-frieren-beyond-the-journeys-end-moewalls-com.mp4"
```

O app aparece como **Waypaper** na barra de menus, sem ícone no Dock. O menu permite escolher outro vídeo, pausar/retomar e encerrar. `swift run Waypaper` abre o último arquivo escolhido; na primeira execução, abre o seletor de arquivo. O caminho é salvo nas preferências locais, não o vídeo. Mover ou remover o arquivo exige selecioná-lo novamente.

- Reprodução em loop, sem áudio, na tela principal; preenche a tela cortando as bordas quando a proporção difere.
- Janela abaixo dos ícones do desktop, sem interceptar cliques e sem modificar o wallpaper do sistema. Encerrar remove a janela.
- Pausa em suspensão/desligamento da tela e quando o macOS notifica a desativação da sessão. Retoma respeitando a pausa manual.
- Se “Reduzir movimento” estiver ativo ao iniciar, começa pausado; é possível retomar pelo menu.
- Não instala agentes, serviços ou inicialização automática.

## Distribuir para outro Mac

Para gerar o aplicativo, no Mac de desenvolvimento com Python 3 e as ferramentas da Apple:

```sh
python3 scripts/package.py
```

O comando compila em release para Apple Silicon (M1/M2/M3 e posteriores), monta o bundle e gera **`dist/Waypaper.zip`**, com assinatura ad hoc. Não inclui vídeos. O destinatário precisa apenas de macOS 13 ou superior, sem Swift, Python ou Xcode instalados.

1. Envie o ZIP por AirDrop.
2. No outro Mac, descompacte e arraste `Waypaper.app` para **Aplicativos**.
3. Abra o app e escolha um vídeo local. Mantenha o vídeo em uma pasta fixa.
4. Se o macOS bloquear por desenvolvedor não verificado, após a tentativa de abertura vá a **Ajustes do Sistema → Privacidade e Segurança → Abrir Mesmo Assim**. Autorize somente o pacote recebido de uma origem confiável; não desative o Gatekeeper.

A assinatura ad hoc não é um certificado Developer ID nem notarização. Este pacote é para compartilhamento direto, não para distribuição pública sem avisos. Para atualizar, encerre o app pelo menu e substitua-o pela nova versão. Para remover, encerre e apague o app; não há serviços instalados.

Verificação do pacote: ZIP extraído, assinatura validada e executável arm64 exercitado com o vídeo local; decodificação, pausa/retomada pelo menu, loop e encerramento passaram. A autorização inicial do Gatekeeper em outro Mac não foi exercitada.

## Verificação executável

Com uma sessão gráfica ativa e o vídeo de 21 segundos fornecido:

```sh
swift run Waypaper --smoke-test "himmel-x-frieren-beyond-the-journeys-end-moewalls-com.mp4"
```

Abre o wallpaper real, aguarda a camada de vídeo apresentar um frame, aciona pausa/retomada pelo menu, verifica que o tempo parou, aguarda um loop completo e aciona encerramento. Imprime `PASS` para cada etapa; falhas encerram com código 1. Timeout de 90 segundos: use um vídeo curto. Esse modo não salva a seleção de arquivo.

O smoke test passou com o MP4 local (H.264, 3840×2160, 60 fps, 21 s). O caminho de erro para arquivo inexistente também foi exercitado. A captura de desktop não estava disponível no ambiente: Finder, Spaces, Mission Control, bloqueio e suspensão ainda precisam de validação visual/manual. O teste automatizado não prova esses comportamentos.

## Limites atuais

Somente a tela principal, com enquadramento de preenchimento. Sem catálogo, downloads, detecção de oclusão por outras janelas, política de bateria ou seleção independente por monitor. O vídeo 4K/60 continua sendo decodificado enquanto ativo, mesmo atrás de outras janelas.

Arquivos de mídia locais e artefatos de compilação são ignorados pelo Git. O app não concede direitos de uso ou redistribuição dos vídeos importados; o arquivo de referência não é um recurso distribuído pelo projeto.
