# BatteryBar

Bateria do mouse Logitech e do fone Sony na barra de menus do macOS, com
ajuste de sensibilidade (DPI) do mouse sem o app da Logitech.

App nativo em Swift/AppKit, sem Dock, para macOS 13 ou superior. Um
arquivo de código, sem dependências, e compila direto com `swiftc`, sem
Xcode.

## Uso

- A barra de menus mostra um ícone de mouse e um de fone, cada um com a
  porcentagem de bateria. Em 15% ou menos o número fica vermelho, e um
  raio aparece quando o aparelho está carregando.
- Aparelho sem leitura (dormindo, desligado ou desconectado) some do
  título até voltar.
- Clique para abrir o menu: bateria de cada aparelho, **Sensibilidade**
  (400, 800, 1200, 1600, 2400 e 3200 DPI), "Atualizar agora", "Abrir ao
  iniciar sessão" (desligado por padrão) e "Sair".
- As leituras se atualizam a cada 60 segundos e quando o Mac acorda.

### Sensibilidade e o perfil interno do mouse

O mouse recusa a mudança de DPI enquanto obedece ao perfil gravado na
memória dele. Por isso, escolher um DPI no menu troca o mouse para o modo
controlado pelo computador. Nesse modo ele ignora o perfil interno (DPI,
botões, taxa de resposta). "Usar perfil interno do mouse", no mesmo
submenu, desfaz.

O DPI escolhido fica salvo e é reaplicado a cada atualização se o mouse
tiver voltado ao perfil interno.

## Aparelhos testados

- **Logitech PRO X 2** no receptor Lightspeed (`046d:c54d`).
- **Sony WH-1000XM4** por Bluetooth.

Outros mouses Logitech com HID++ 2.0 em receptor USB devem funcionar para
a bateria, mas não foram testados. O nome do fone está fixo em
`SonyReader.nameHint`, em `Sources/main.swift`; para outro fone que o
macOS liste em `pmset -g accps`, basta trocar esse nome.

## Instalar

Precisa do Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/vleineker/battery-bar.git
cd battery-bar
./build.sh
open build/BatteryBar.app
```

O app é assinado localmente (ad-hoc) pelo `build.sh`. Para mantê-lo, copie
`build/BatteryBar.app` para `~/Applications`.

## Linha de comando

```bash
B=build/BatteryBar.app/Contents/MacOS/BatteryBar
$B --list           # leituras cruas de bateria e DPI
$B --set-dpi 1600   # define o DPI (100 a 6400)
$B --onboard        # devolve o controle ao perfil interno do mouse
```

## Como funciona

- **Mouse:** protocolo HID++ 2.0 da Logitech pelo receptor (vendor
  `046d`, usage page `FF00`), com a API de HID do macOS. Bateria pelo
  recurso `0x1004`, com `0x1000` de reserva. Não pede permissão.
- **Sensibilidade:** recurso `0x2202` para ler e definir o DPI, e recurso
  `0x8100` para alternar entre o perfil interno e o modo controlado pelo
  computador. São as únicas escritas feitas no mouse.
- **Fone:** linha do aparelho em `pmset -g accps`.

## Limitações

- Não foi verificado se o mouse volta sozinho ao perfil interno ao ser
  desligado.
- O mouse às vezes não responde ao receptor por alguns instantes; a
  bateria dele some do título até a próxima leitura.
- O fone só aparece enquanto está conectado ao Mac.
- Mouse por Bluetooth e receptores Unifying ou Bolt não foram testados.

## Créditos

O formato das mensagens veio da documentação do HID++ 2.0 e da pesquisa
do [Solaar](https://github.com/pwr-Solaar/Solaar). A ideia veio do
[Wireless Battery](https://github.com/krisgfx9/Wireless-Device-Battery-Monitor),
que faz o mesmo no Windows. Nenhum código desses projetos foi copiado.

## Contribuir e licença

Como compilar e mandar mudanças: [`CONTRIBUTING.md`](CONTRIBUTING.md).
Código sob a licença MIT ([`LICENSE`](LICENSE)).
